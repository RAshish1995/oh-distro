#include "manip_plan.h"
#include "generate_spline.h"
#include "drake/util/lcmUtil.h"

#include <fstream>
#include <iomanip>

namespace plan_eval {

drake::lcmt_qp_controller_input ManipPlan::MakeQPInput(const DrakeRobotState &est_rs) {
  double cur_time = est_rs.t;

  if (generic_plan_state_.plan_start_time == -1)
    generic_plan_state_.plan_start_time = cur_time;
  double plan_time = cur_time - generic_plan_state_.plan_start_time;

  bool apply_torque_alpha_filter = plan_time < generic_plan_config_.initial_transition_time;

  // record some debug data
  this->RecordDefaultDebugData(plan_time);
  debug_data_.plan_type = "manip";
  return MakeDefaultQPInput(cur_time, plan_time, param_set_name_, apply_torque_alpha_filter);
}

Eigen::VectorXd ManipPlan::GetLatestKeyFrame(double cur_time) {
  if (generic_plan_state_.plan_start_time == -1)
    generic_plan_state_.plan_start_time = cur_time;
  double plan_time = cur_time - generic_plan_state_.plan_start_time;

  return q_trajs_.value(plan_time);
}

void ManipPlan::HandleCommittedRobotPlan(const void *plan_msg,
                                         const DrakeRobotState &est_rs,
                                         const Eigen::VectorXd &last_q_d) {
  const drc::robot_plan_t *msg = (const drc::robot_plan_t *) plan_msg;

  // record time at which this plan was constructed
  this->plan_construction_time_in_seconds_ = est_rs.t;
  std::ofstream out;

  // record the param set name to use
  param_set_name_ = msg->param_set;

  size_t num_T = msg->plan.size();
  //size_t num_T = msg->plan.size() + 1;

  std::vector<double> Ts(num_T);
  std::vector <Eigen::Vector2d> com_d(num_T);
  std::vector <Eigen::VectorXd> q_d(num_T);  // t steps by n

  // BodyMotionData tracking for the pelvis and both feet
  std::vector<int> body_ids;
  body_ids.push_back(rpc_.pelvis_id);
  for (auto it = rpc_.foot_ids.begin(); it != rpc_.foot_ids.end(); it++) {
    std::cout << "ManipPlan: foot_ids = " << it->second << std::endl;
    body_ids.push_back(it->second);
  }

  // for some reason RBT.findLink wants the string name
  std::vector<std::string> body_names;
  for (int i = 0; i < body_ids.size(); i++){
    body_names.push_back(this->robot_.getBodyOrFrameName(body_ids[i]));
  }


  // body_names.push_back(robot_.getBodyOrFrameName(rpc_.pelvis_id));
  // for (auto it = rpc_.foot_ids.begin(); it != rpc_.foot_ids.end(); it++) {
  //   std::cout << "ManipPlan: foot_ids = " << it->second << std::endl;
  //   body_names.push_back(robot_.getBodyOrFrameName(it->second));
  // }
  size_t num_bodies = body_names.size();

  std::vector <std::vector<Eigen::Matrix<double, 7, 1>>> x_d(num_bodies);
  std::vector <std::vector<Eigen::Matrix<double, 7, 1>>> xd_d(num_bodies);
  for (size_t i = 0; i < num_bodies; i++) {
    x_d[i].resize(num_T);
    xd_d[i].resize(num_T);
  }

  // generate the current tracked body poses from the estimated robot state
  // maybe useful eventually
  KinematicsCache<double> cache_est = robot_.doKinematics(est_rs.q, est_rs.qd);
  std::vector <Eigen::Matrix<double, 7, 1>> x_est(num_bodies);
  for (size_t b = 0; b < num_bodies; b++) {
    // int id = robot_.findLink(body_names[b])->body_index;
    int id = body_ids[b];
    Eigen::Isometry3d pose = robot_.relativeTransform(cache_est, 0, id);
    x_est[b].segment<3>(0) = pose.translation();
    x_est[b].segment<4>(3) = rotmat2quat(pose.linear());
    std::cout << "cur pose " << body_names[b] << " " << x_est[b].segment<4>(3).transpose() << std::endl;
  }

  // generate q_traj first w. cubic spline, which gives velocities.
  for (size_t t = 0; t < num_T; t++) {
    const bot_core::robot_state_t &keyframe = msg->plan[t];
    KeyframeToState(keyframe, q_, v_);
    Ts[t] = (double) keyframe.utime / 1e6;
    q_d[t] = q_;
  }

  // make q, v splines, make sure to set t0 and t1 vel to zero
  Eigen::VectorXd zero = Eigen::VectorXd::Zero(q_d[0].size());
  q_trajs_ = GenerateCubicSpline(Ts, q_d, zero, zero);
  auto v_trajs = q_trajs_.derivative();

  // go through Ts again to make trajs for all the cartesian stuff
  for (size_t t = 0; t < num_T; t++) {
    q_ = q_trajs_.value(Ts[t]);
    v_ = v_trajs.value(Ts[t]);

    KinematicsCache<double> cache_plan = robot_.doKinematics(q_, v_);

    for (size_t b = 0; b < num_bodies; b++) {
      const RigidBody *body = robot_.findLink(body_names[b]).get();
      int id = body->body_index;
      Eigen::Isometry3d pose = robot_.relativeTransform(cache_plan, 0, id);
      x_d[b][t].segment<3>(0) = pose.translation();
      x_d[b][t].segment<4>(3) = rotmat2quat(pose.linear());

      Eigen::Vector6d xd =
          GetTaskSpaceVel(robot_, cache_plan, *body, Eigen::Vector3d::Zero());
      xd_d[b][t].segment<3>(0) = xd.segment<3>(3);
      // http://www.euclideanspace.com/physics/kinematics/angularvelocity/QuaternionDifferentiation2.pdf
      Eigen::Vector4d W(0, xd[0], xd[1], xd[2]);
      xd_d[b][t].segment<4>(3) = 0.5 * quatProduct(W, x_d[b][t].segment<4>(3));
    }

    // get com
    com_d[t] = robot_.centerOfMass(cache_plan).segment<2>(0);
  }


  // make zmp traj, since we are manip, com ~= zmp, zmp is created with pchip
  Eigen::Vector2d zero2(Eigen::Vector2d::Zero());
  generic_plan_state_.zmp_traj = GeneratePCHIPSpline(Ts, com_d, zero2, zero2);
  // TODO: make traj for s1, and com
  // drake/examples/ZMP/LinearInvertedPendulum.m

  Eigen::Vector4d x0(Eigen::Vector4d::Zero());
  x0.head(2) = com_d[0];
  zmp_planner_.Plan(generic_plan_state_.zmp_traj, x0, generic_plan_config_.zmp_height);

  // make body motion splines
  generic_plan_state_.body_motions.resize(num_bodies);
  for (size_t b = 0; b < num_bodies; b++) {

    

    // old code
    generic_plan_state_.body_motions[b] = MakeDefaultBodyMotionData(num_T);
    generic_plan_state_.body_motions[b].body_or_frame_id =
        robot_.findLink(body_names[b])->body_index;
    generic_plan_state_.body_motions[b].trajectory =
        GenerateCubicCartesianSpline(Ts, x_d[b], xd_d[b]);

    if (body_names[b].compare(robot_.getBodyOrFrameName(rpc_.pelvis_id)) == 0){
      generic_plan_state_.body_motions[b].control_pose_when_in_contact.resize(num_T, true);
    }



    //new code
    int body_id = this->robot_.findLink(body_names[b])->body_index;
    this->generic_plan_state_.body_motion_data_map_[body_id] = MakeDefaultBodyMotionData(num_T);
    // shorter name for referencing
    BodyMotionData& body_motion_data = this->generic_plan_state_.body_motion_data_map_[body_id];
    body_motion_data.trajectory = GenerateCubicCartesianSpline(Ts, x_d[b], xd_d[b]);

    // if it's the pelvis then control while in contact
    if (body_names[b].compare(robot_.getBodyOrFrameName(rpc_.pelvis_id)) == 0){
      generic_plan_state_.body_motions[b].control_pose_when_in_contact.resize(num_T, true);
    }    

  }

  // make support, dummy here since we are always in double support
  generic_plan_state_.support_state = MakeDefaultSupportState(ContactState::DS());

  // constrained DOFs
  // TODO: this is not true for dragging hands around
  constrained_dofs_.clear();
  for (auto it = rpc_.position_indices.arms.begin(); it != rpc_.position_indices.arms.end(); it++) {
    const std::vector<int> &indices = it->second;
    for (size_t i = 0; i < indices.size(); i++)
      constrained_dofs_.push_back(indices[i]);
  }
  // neck
  for (size_t i = 0; i < rpc_.position_indices.neck.size(); i++)
    constrained_dofs_.push_back(rpc_.position_indices.neck[i]);
  // back
  constrained_dofs_.push_back(rpc_.position_indices.back_bkz);
  //constrained_dofs_.push_back(rpc_.position_indices.back_bky);

  std::cout << "committed robot plan proced\n";
}
}// plan_eval