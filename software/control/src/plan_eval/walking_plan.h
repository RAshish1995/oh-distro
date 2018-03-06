#pragma once

#include "footstep_plan.h"
#include "generic_plan.h"
#include "contact_plan.h"
#include <list>
#include <utility>
#include <memory>
#include <lcm/lcm-cpp.hpp>

namespace plan_eval {


// seems redundant with ContactState which can be
// SSL, SSR, or DS
enum WalkingState {
  WEIGHT_TRANSFER,
  SWING
};

// State that is specific to the walking planner, and doesn't fit in GenericPlanState
// everything stateful about the walking planner should be contained here
struct WalkingPlanState {
  WalkingState walking_state;
  std::list <std::pair<ContactState, double>> contact_state;
  PiecewisePolynomial<double> weight_distribution;
  double contact_switch_time = -INFINITY; // deprecated
  double next_contact_switch_time; // deprecated
  bool have_tared_swing_leg_ft = false;
  std::shared_ptr<FootstepPlan> footstep_plan_ptr;
  std::shared_ptr<ContactPlan> contact_plan;
};



class WalkingPlan : public GenericPlan {
public:
  WalkingPlan(const std::string &urdf_name, const std::string &config_name) : GenericPlan(urdf_name, config_name) {

    generic_plan_state_.plan_status.planType = PlanType::WALKING;

    // check the lcm handle initialization was good
    if (!lcm_handle_.good()) {
      throw std::runtime_error("lcm is not good()");
    }
  }

  void HandleCommittedRobotPlan(const void *plan_msg,
                                const DrakeRobotState &rs,
                                const Eigen::VectorXd &last_q_d);

  drake::lcmt_qp_controller_input MakeQPInput(const DrakeRobotState &rs);

  Eigen::VectorXd GetLatestKeyFrame(double time) { return Eigen::VectorXd::Zero(robot_.num_positions); }

private:

  lcm::LCM lcm_handle_;

  WalkingPlanState walking_plan_state_;
  Eigen::VectorXd init_q_;

  // the bodies that will have associated body motion datas
  std::vector<int> body_motion_data_ids_; 

  WalkingState checkGuards(const DrakeRobotState &est_rs) const;
  void doTransitionActions(const DrakeRobotState &est_rs, WalkingState next_state);
  void doStandardActions(const DrakeRobotState &est_rs);

  void GenerateTrajs(double plan_time, const Eigen::VectorXd &est_q, const Eigen::VectorXd &est_qd,
                     const ContactState &cur_contact_state);

  WalkingState WeightTransferToSwingGuard(const DrakeRobotState &est_rs) const;

  WalkingState SwingToWeightTransferGuard(const DrakeRobotState &est_rs) const;

  void WeightTransferToSwingActions(const DrakeRobotState &est_rs);
  void SwingToWeightTransferActions(const DrakeRobotState &est_rs);
  void SwingStandardActions(const DrakeRobotState &est_rs);

  inline BodyMotionData &get_pelvis_body_motion_data() { return generic_plan_state_.body_motions[0]; }

  inline BodyMotionData &get_torso_body_motion_data() { return generic_plan_state_.body_motions[1]; }

  inline BodyMotionData &get_stance_foot_body_motion_data() { return generic_plan_state_.body_motions[2]; }

  inline BodyMotionData &get_swing_foot_body_motion_data() { return generic_plan_state_.body_motions[3]; }

  inline Eigen::Vector7d bot_core_pose2pose(const bot_core::position_3d_t &p) const {
    Eigen::Vector7d pose;
    pose[0] = p.translation.x;
    pose[1] = p.translation.y;
    pose[2] = p.translation.z;
    pose[3] = p.rotation.w;
    pose[4] = p.rotation.x;
    pose[5] = p.rotation.y;
    pose[6] = p.rotation.z;
    pose.tail(4).normalize();
    return pose;
  }

  Eigen::Vector2d Footstep2DesiredZMP(Side side, const Eigen::Isometry3d &step) const;
  Eigen::Vector2d Footstep2DesiredZMP(const Footstep & footstep) const;


  PiecewisePolynomial<double>
  PlanZMPTraj(const std::vector <Eigen::Vector2d> &zmp_d,
              int num_of_zmp_knots,
              const Eigen::Vector2d &zmp_d0,
              const Eigen::Vector2d &zmpd_d0,
              const double & plan_time,
              double time_before_weight_shift) const;

  void SwitchContactState(double cur_time);

  void TareSwingLegForceTorque();

  PiecewisePolynomial<double>
  GenerateSwingTraj(const Eigen::Matrix<double, 7, 1> &foot0, const Eigen::Matrix<double, 7, 1> &foot1,
                    double mid_z_offset, double pre_swing_dur, double swing_up_dur, double swing_transfer_dur,
                    double swing_down_dur) const;

  PiecewisePolynomial<double> GeneratePelvisTraj(const std::vector<double>& times,
                                                 const std::vector<Eigen::Isometry3d>& pelvis_poses);

  static double get_weight_distribution(const ContactState &cs);
};

}// plan eval