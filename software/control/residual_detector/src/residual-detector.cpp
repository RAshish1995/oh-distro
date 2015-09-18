#include <mutex>
#include <thread>
#include "FootContactDriver.hpp"
#include "drake/ForceTorqueMeasurement.h"
#include "lcmtypes/drc/robot_state_t.hpp"
#include "drake/Side.h"
#include "drake/QPCommon.h"
#include "RobotStateDriver.hpp"
#include <lcm/lcm-cpp.hpp>
#include <model-client/model-client.hpp>
#include <bot_param/param_client.h>
#include <Eigen/Core>
#include <string>
#include <memory>
#include <vector>

#define RESIDUAL_GAIN 10.0;
#define PUBLISH_CHANNEL "RESIDUAL_OBSERVER_STATE"
using namespace Eigen;

struct ResidualDetectorState{
  double t_prev;
  VectorXd r;
  VectorXd integral;
  VectorXd gamma;
  VectorXd p_0;
  bool running;

};

struct ResidualArgs{
  // information that updateResidualState will need
  std::shared_ptr<DrakeRobotStateWithTorque> robot_state;
  std::map<Side, ForceTorqueMeasurement> foot_force_torque_measurement;
  std::map<Side, bool> b_contact_force;
};

class ResidualDetector{

public:
  // forward declaration
  ResidualDetector(std::shared_ptr<lcm::LCM> &lcm_, bool verbose_);
  ~ResidualDetector(){
  }
  void residualThreadLoop();

private:
  std::shared_ptr<lcm::LCM> lcm_;
  std::shared_ptr<ModelClient> model_;
  bool running_;
  bool verbose_;
  bool newStateAvailable;
  int nq;
  int nv;
  double t_prev;
  BotParam* botparam_;
  RigidBodyManipulator drake_model;
  std::mutex pointerMutex;
  std::vector<std::string> state_coordinate_names;
  std::string publishChannel;

  VectorXd residualGainVector;
  double residualGain;
  ResidualArgs args;
  ResidualDetectorState residual_state;
  ResidualDetectorState residual_state_w_forces;
  drc::robot_state_t residual_state_msg;


  std::map<Side, int> foot_body_ids;

  std::shared_ptr<RobotStateDriver> state_driver;
  std::shared_ptr<FootContactDriver> foot_contact_driver;

  void onRobotState(const lcm::ReceiveBuffer* rbuf, const std::string& channel, const  drc::robot_state_t* msg);
  void onFootContact(const lcm::ReceiveBuffer* rbuf, const std::string& channel, const drc::foot_contact_estimate_t* msg);
  void updateResidualState();
  void publishResidualState(std::string publish_channel, const ResidualDetectorState &);

};


ResidualDetector::ResidualDetector(std::shared_ptr<lcm::LCM> &lcm_, bool verbose_):
    lcm_(lcm_), verbose_(verbose_), newStateAvailable(false){

  do {
    botparam_ = bot_param_new_from_server(lcm_->getUnderlyingLCM(), 0);
  } while(botparam_ == NULL);

  std::shared_ptr<ModelClient> model = std::shared_ptr<ModelClient>(new ModelClient(lcm_->getUnderlyingLCM(),0));
  drake_model.addRobotFromURDFString(model->getURDFString());
  drake_model.compile();

  lcm_->subscribe("EST_ROBOT_STATE", &ResidualDetector::onRobotState, this);
  lcm_->subscribe("FOOT_CONTACT_ESTIMATE", &ResidualDetector::onFootContact, this);


  //need to initialize the state_driver
//  std::cout << "this should only be printed once" << std::endl;
//  std::vector<std::string> state_coordinate_names;

  // build this up manually for now, hacky solution
  this->nq = drake_model.num_positions;
  this->nv = drake_model.num_velocities;

  for(int i = 0; i < this->nq; i++){
    std::string joint_name = drake_model.getStateName(i);
    this->state_coordinate_names.push_back(joint_name);
  }

  state_driver.reset(new RobotStateDriver(this->state_coordinate_names));


  // initialize foot_contact_driver
  BodyIdsCache body_ids_cache;
  body_ids_cache.r_foot = drake_model.findLinkId("r_foot");
  body_ids_cache.l_foot = drake_model.findLinkId("l_foot");
  body_ids_cache.pelvis = drake_model.findLinkId("pelvis");

  this->foot_body_ids[Side::LEFT] = body_ids_cache.l_foot;
  this->foot_body_ids[Side::RIGHT] = body_ids_cache.r_foot;

  this->args.b_contact_force[Side::LEFT] = false;
  this->args.b_contact_force[Side::RIGHT] = false;

  foot_contact_driver.reset(new FootContactDriver(body_ids_cache));

  // initialize the residual_state
  residual_state.t_prev = 0;
  residual_state.r = VectorXd::Zero(nq);
  residual_state.integral = VectorXd::Zero(nq);
  residual_state.gamma = VectorXd::Zero(nq);
  residual_state.p_0 = VectorXd::Zero(nq);
  residual_state.running = false;

  // initialize the residual_state
  residual_state_w_forces.t_prev = 0;
  residual_state_w_forces.r = VectorXd::Zero(nq);
  residual_state_w_forces.integral = VectorXd::Zero(nq);
  residual_state_w_forces.gamma = VectorXd::Zero(nq);
  residual_state_w_forces.p_0 = VectorXd::Zero(nq);
  residual_state_w_forces.running = false;

  this->residualGain = RESIDUAL_GAIN;
  this->publishChannel = PUBLISH_CHANNEL;
  this->residualGainVector = residualGain*VectorXd::Ones(this->nq);


  //TEST
  t_prev = 0;
  return;

}

void ResidualDetector::onRobotState(const lcm::ReceiveBuffer *rbuf, const std::string &channel,
                                    const drc::robot_state_t *msg) {

//  if (this->verbose_) {
//    std::cout << "got a robot state message" << std::endl;
//  }

  std::shared_ptr<DrakeRobotStateWithTorque> state(new DrakeRobotStateWithTorque);
  int nq = this->drake_model.num_positions;
  int nv = this->drake_model.num_velocities;
  state->q = VectorXd::Zero(nq);
  state->qd = VectorXd::Zero(nv);
  state->torque = VectorXd::Zero(nq);

  this->state_driver->decodeWithTorque(msg, state.get());

  // aquire a lock and write to the shared_ptr for robot_state_
  std::unique_lock<std::mutex> lck(this->pointerMutex);

  this->args.robot_state = state;

  const drc::force_torque_t& force_torque = msg->force_torque;

  this->args.foot_force_torque_measurement[Side::LEFT].frame_idx = this->foot_body_ids[Side::LEFT];
  this->args.foot_force_torque_measurement[Side::LEFT].wrench << force_torque.l_foot_torque_x, force_torque.l_foot_torque_y, 0.0, 0.0, 0.0, force_torque.l_foot_force_z;

  this->args.foot_force_torque_measurement[Side::RIGHT].frame_idx = this->foot_body_ids[Side::RIGHT];
  this->args.foot_force_torque_measurement[Side::RIGHT].wrench << force_torque.r_foot_torque_x, force_torque.r_foot_torque_y, 0.0, 0.0, 0.0, force_torque.r_foot_force_z;


  lck.unlock();
  this->newStateAvailable = true;


}

void ResidualDetector::onFootContact(const lcm::ReceiveBuffer *rbuf, const std::string &channel,
                                     const drc::foot_contact_estimate_t *msg) {

  std::unique_lock<std::mutex> lck(pointerMutex);
  this->args.b_contact_force[Side::LEFT] = msg->left_contact > 0.5;
  this->args.b_contact_force[Side::RIGHT] = msg->right_contact > 0.5;
  lck.unlock();
}

void ResidualDetector::updateResidualState() {

  // acquire a lock and copy data to local variables
  std::unique_lock<std::mutex> lck(this->pointerMutex);
  std::shared_ptr<DrakeRobotStateWithTorque> robot_state = this->args.robot_state;
  const std::map<Side, ForceTorqueMeasurement>& foot_force_torque_measurement = this->args.foot_force_torque_measurement;
  const auto & b_contact_force = this->args.b_contact_force;
  this->newStateAvailable = false;
  lck.unlock();

  double t = robot_state->t;
  double dt = t - this->residual_state.t_prev;


  // compute H for current state (q,qd)
  this->drake_model.doKinematics(robot_state->q, robot_state->qd, true);

  // could replace this GradVar declaration with auto?
  GradientVar<double, Eigen::Dynamic, Eigen::Dynamic> gradVar = this->drake_model.massMatrix<double>(1);
  const auto & H = gradVar.value();

  MatrixXd H_grad = gradVar.gradient().value(); // size nq^2 x nq

  //FOOT CONTACT FORCES: Compute torques due to foot contact forces
  std::map<Side, VectorXd> foot_force_contact_torques;
  MatrixXd footJacobian; // should be 3 x nv
  Vector3d points(0,0,0); //point is at origin of foot frame

  for (const auto& side_force: foot_force_torque_measurement){
    const Side& side = side_force.first;
    int body_id = this->foot_body_ids[side];

    if (this->verbose_){
      if (b_contact_force.at(side)){
        std::cout << std::cout << side.toString() << " foot in contact" << std::endl;
      }
      else{
        std::cout << std::cout << side.toString() << " foot NOT in contact" << std::endl;
      }
    }
    //check if this body is actually in contact or not
    if (!b_contact_force.at(side)){
      foot_force_contact_torques[side] = VectorXd::Zero(this->nq);
      continue;
    }

    footJacobian = this->drake_model.forwardKinJacobian(points, body_id, 0, 0, true, 0).value();
    const Vector3d & force = side_force.second.wrench.block(3,0,3,1);
    foot_force_contact_torques[side_force.first] = footJacobian.transpose()*force;

    if (this->verbose_){
      std::cout << side.toString() << " foot force is " << std::endl;
      std::cout << force << std::endl;

      std::cout << "z torque passed through Jacobian is " << foot_force_contact_torques[side](2) << std::endl;
    }
  }

  //compute the gravitational term in manipulator equations, hack by calling doKinematics with zero velocity
  VectorXd qd_zero = VectorXd::Zero(this->nq);
  this->drake_model.doKinematics(robot_state->q, qd_zero, true);
  // dummy of zero external forces
  std::map<int, std::unique_ptr< GradientVar<double, TWIST_SIZE, 1> > > f_ext; //hopefully TWIST_SIZE has been defined in a header i've imported
  VectorXd gravity = this->drake_model.inverseDynamics(f_ext).value();

  // computes a vector whose i^th entry is g_i(q) - 1/2*qd^T*dH/dq_i*qd
  VectorXd alpha = VectorXd::Zero(this->nq);
  for (int i=0; i<this->nq; i++){
    int row_idx = i*this->nq;
    alpha(i) = gravity(i) - 1/2*robot_state->qd.transpose()*H_grad.block(row_idx,0,this->nq, this->nq)*robot_state->qd;
  }


  // this is the generalized momentum
  VectorXd p_momentum = H*robot_state->qd;

  //Special case for the first time we enter the loop
  //if this is the first time we are entering the loop, then set p_0, and return. Residual stays at 0
  if (!this->residual_state.running){
    std::cout << "started residual detector updates" << std::endl;
    this->residual_state.running = true;
    this->residual_state.p_0 = p_momentum;

    this->residual_state_w_forces.running = true;
    this->residual_state_w_forces.p_0 = p_momentum;
    return;
  }



  // UPDATE STEP
  // First compute new state for residual, only new information this uses is dt, and p_momentum
  VectorXd integral_new = this->residual_state.integral + dt*this->residual_state.gamma;
  VectorXd r_new = this->residualGain*(p_momentum - this->residual_state.p_0 + integral_new);

  VectorXd integral_new_w_forces = this->residual_state_w_forces.integral + dt*this->residual_state_w_forces.gamma;
  VectorXd r_new_w_forces = this->residualGain*(p_momentum - this->residual_state_w_forces.p_0 + integral_new_w_forces);

  // update the residual state
  this->residual_state.r = r_new;
  this->residual_state.integral = integral_new;
  this->residual_state.gamma = alpha - robot_state->torque - this->residual_state.r; // this is the integrand;

  // update the residual state with forces
  this->residual_state_w_forces.r = r_new_w_forces;
  this->residual_state_w_forces.integral = integral_new_w_forces;
  this->residual_state_w_forces.gamma = alpha - robot_state->torque - this->residual_state_w_forces.r -
      foot_force_contact_torques[Side::LEFT] - foot_force_contact_torques[Side::RIGHT]; // this is the integrand;

  this->residual_state.t_prev = t;
  if (this->verbose_){
    double Hz = 1/dt;
    std::cout << "residual update running at " << Hz << std::endl;
  }

  //publish over LCM
  this->publishResidualState(this->publishChannel, this->residual_state);
  this->publishResidualState("RESIDUAL_OBSERVER_STATE_WITH_FORCES", this->residual_state_w_forces);
}

void ResidualDetector::publishResidualState(std::string publishChannel, const ResidualDetectorState &residual_state){


  std::unique_lock<std::mutex> lck(pointerMutex);
  this->residual_state_msg.utime = static_cast<int64_t> (this->args.robot_state->t * 1e6);
  lck.unlock();

  this->residual_state_msg.num_joints = (int16_t) this->nq;
  this->residual_state_msg.joint_name = this->state_coordinate_names;
  this->residual_state_msg.joint_position.resize(this->nq);
  this->residual_state_msg.joint_velocity.resize(this->nq);
  this->residual_state_msg.joint_effort.resize(this->nq);

  for (int i=0; i < this->nq; i++){
    this->residual_state_msg.joint_position[i] = (float) residual_state.r(i);
  }

  if (this->verbose_){
    std::cout << "base_z residual is " << residual_state.r(2) << std::endl;
    std::cout << "base_z residual in message is " << this->residual_state_msg.joint_position[2] << std::endl;
  }

  this->lcm_->publish(publishChannel, &residual_state_msg);
}

void ResidualDetector::residualThreadLoop() {
  bool done = false;

  while (!done){
    while(!this->newStateAvailable){
      std::this_thread::yield();
    }
    this->updateResidualState();
  }
}

int main( int argc, char** argv){
  std::cout << "Hello World \n";

  std::shared_ptr<lcm::LCM> lcm(new lcm::LCM);
  if(!lcm->good()){
    std::cerr << "Error: lcm is not good()" << std::endl;
  }

  ResidualDetector residualDetector(lcm, true);
  std::thread residualThread(&ResidualDetector::residualThreadLoop, &residualDetector);
  std::cout << "started residual thread loop" << std::endl;

  // in the main thread run the lcm handler
  std::cout << "Starting lcm handler loop" << std::endl;
  while(0 == lcm->handle());
  return 0;
}
