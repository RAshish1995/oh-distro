function atlasCOPTracking
%NOTEST
addpath(fullfile(getDrakePath,'examples','ZMP'));

joint_str = {'leg','back'};% <---- cell array of (sub)strings

% load robot model
% load phat_lf_0p7_rmse_1p34_cm;
% load phat_utorso_l_hand_only_lf_0p8_rmse_1p23_cm.mat;
% r = Atlas(strcat(getenv('DRC_PATH'),'/models/mit_gazebo_models/mit_robot_drake/model_param_simplified.urdf'));
% r = r.setParams(double(phat));

r = Atlas();
r = removeCollisionGroupsExcept(r,{'toe','heel'});
r = compile(r);
load(strcat(getenv('DRC_PATH'),'/control/matlab/data/atlas_fp.mat'));
r = r.setInitialState(xstar);

% setup frames
state_plus_effort_frame = AtlasStateAndEffort(r);
state_plus_effort_frame.subscribe('EST_ROBOT_STATE');
input_frame = getInputFrame(r);
ref_frame = AtlasPosVelTorqueRef(r);

nu = getNumInputs(r);
nq = getNumDOF(r);

act_idx_map = getActuatedJoints(r);
gains = getAtlasGains(); % change gains in this file

joint_ind = [];
joint_act_ind = [];
for i=1:length(joint_str)
  joint_ind = union(joint_ind,find(~cellfun(@isempty,strfind(state_plus_effort_frame.coordinates(1:nq),joint_str{i}))));
  joint_act_ind = union(joint_act_ind,find(~cellfun(@isempty,strfind(input_frame.coordinates,joint_str{i}))));
end

% zero out force gains to start --- move to nominal joint position
gains.k_f_p = zeros(nu,1);
gains.ff_f_d = zeros(nu,1);
gains.ff_qd = zeros(nu,1);
gains.ff_qd_d = zeros(nu,1);
ref_frame.updateGains(gains);

% move to fixed point configuration
qdes = xstar(1:nq);
atlasLinearMoveToPos(qdes,state_plus_effort_frame,ref_frame,act_idx_map,5);

gains_copy = getAtlasGains();
% reset force gains for joint being tuned
gains.k_f_p(joint_act_ind) = gains_copy.k_f_p(joint_act_ind);
gains.ff_f_d(joint_act_ind) = gains_copy.ff_f_d(joint_act_ind);
gains.ff_qd(joint_act_ind) = gains_copy.ff_qd(joint_act_ind);
gains.ff_qd_d(joint_act_ind) = gains_copy.ff_qd_d(joint_act_ind);
% set joint position gains to 0 for joint being tuned
gains.k_q_p(joint_act_ind) = 0;
gains.k_q_i(joint_act_ind) = 0;
gains.k_qd_p(joint_act_ind) = 0;

ref_frame.updateGains(gains);

% get current state
[x,~] = getMessage(state_plus_effort_frame);
x0 = x(1:2*nq);
q0 = x0(1:nq);
kinsol = doKinematics(r,q0);

T = 30;
if 0
  % create figure 8 zmp traj
  dt = 0.01;
  ts = 0:dt:T;
  nt = T/dt;
  radius = 0.04; % 8 loop radius
  zmpx = [radius*sin(4*pi/T * ts(1:nt/2)), radius*sin(4*pi/T * ts(1:nt/2+1))];
  zmpy = [radius-radius*cos(4*pi/T * ts(1:nt/2)), -radius+radius*cos(4*pi/T * ts(1:nt/2+1))];
else
%   % back and forth
%   w=0.1; 
%   zmpx = [0 0  0 0  0 0  0 0  0 0];
%   zmpy = [0 w -w w -w w -w w -w 0];
%   
%   np=length(zmpy);
%   ts = linspace(0,T,np);

  % rectangle
  h=0.015; % height/2
  w=0.08; % width/2
  zmpx = [0 h h -h -h 0];
  zmpy = [0 w -w -w w 0];
  ts = [0 T/5 2*T/5 3*T/5 4*T/5 T];
end

zmpknots = [zmpx;zmpy;0*zmpx];
R = rpy2rotmat([0;0;x0(6)]);
zmpknots = R*zmpknots;
zmptraj = PPTrajectory(foh(ts,zmpknots(1:2,:)));

rfoot_ind = r.findLinkInd('r_foot');
lfoot_ind = r.findLinkInd('l_foot');
foot_pos = terrainContactPositions(r,q0,[rfoot_ind, lfoot_ind]); 
foot_center = mean([mean(foot_pos(1:2,1:4)');mean(foot_pos(1:2,5:8)')])';
zmptraj = zmptraj + foot_center;
zmptraj = zmptraj.setOutputFrame(desiredZMP);

com = getCOM(r,kinsol);
options.com0 = com(1:2);
zfeet = min(foot_pos(3,:));
[K,~,comtraj] = LinearInvertedPendulum.ZMPtrackerClosedForm(com(3)-zfeet,zmptraj,options);
% 
% % get COM traj from desired ZMP traj
% options.com0 = com(1:2);
% options.Qy = 
% 
% K = ZMPtracker(obj,dZMP,options)
% 
%     function [ct,Vt,comtraj] = ZMPtracker(obj,dZMP,options)




% plot zmp/com traj in drake viewer
lcmgl = drake.util.BotLCMGLClient(lcm.lcm.LCM.getSingleton(),'zmp-traj');
ts = 0:0.1:T;
for i=1:length(ts)
  lcmgl.glColor3f(0, 1, 0);
	lcmgl.sphere([zmptraj.eval(ts(i));0], 0.01, 20, 20);  
  lcmgl.glColor3f(1, 1, 0);
	lcmgl.sphere([comtraj.eval(ts(i));0], 0.01, 20, 20);  
end
lcmgl.switchBuffers();

foot_support = SupportState(r,find(~cellfun(@isempty,strfind(r.getLinkNames(),'foot'))));
foottraj.right.orig = ConstantTrajectory(forwardKin(r,kinsol,rfoot_ind,[0;0;0],1));
foottraj.left.orig = ConstantTrajectory(forwardKin(r,kinsol,lfoot_ind,[0;0;0],1));
link_constraints = buildLinkConstraints(r, q0, foottraj);

ctrl_data = SharedDataHandle(struct(...
  'is_time_varying',true,...
  'x0',[zmptraj.eval(T);0;0],...
  'support_times',0,...
  'supports',foot_support,...
  'ignore_terrain',false,...
  'trans_drift',[0;0;0],...
  'qtraj',q0,...
  'K',K,...
  'comtraj',comtraj,...
  'mu',1,...
  'link_constraints',link_constraints,...
  'constrained_dofs',[findJointIndices(r,'arm');findJointIndices(r,'back');findJointIndices(r,'neck')]));

use_simple_pd = true;
constrain_torso = true;

if use_simple_pd
  
  options.Kp = 30*ones(6,1);
  options.Kd = 10*ones(6,1);
  lfoot_motion = FootMotionControlBlock(r,'l_foot',ctrl_data,options);
  rfoot_motion = FootMotionControlBlock(r,'r_foot',ctrl_data,options);
  
  options.Kp = 40*[0; 0; 1; 1; 1; 1];
  options.Kd = 10*[0; 0; 1; 1; 1; 1];
  pelvis_motion = TorsoMotionControlBlock(r,'pelvis',ctrl_data,options);
  
  options.Kp = 40*[0; 0; 0; 1; 1; 1];
  options.Kd = 10*[0; 0; 0; 1; 1; 1];
  torso_motion = TorsoMotionControlBlock(r,'utorso',ctrl_data,options);
	
  options.w_qdd = 0.0001*ones(nq,1);
  options.w_qdd(1:6) = 0;
  options.w_qdd(findJointIndices(r,'hpz')) = 1.0;
  options.W_hdot = diag([1;1;1;100000;100000;100000]);
  options.Kp = 0; % com-z pd gains
  options.Kd = 0; % com-z pd gains
  options.body_accel_input_weights = [-1 -1 1 1];
else
  options.w_qdd = 10*ones(nq,1);
  options.W_hdot = diag([10;10;10;10;10;10]);
  options.Kp = 0; % com-z pd gains
  options.Kd = 0; % com-z pd gains
end

% instantiate QP controller
options.slack_limit = 100;
options.w_slack = 0.005;
options.w_grf = 0.01;
options.input_foot_contacts = true;
options.debug = true;
options.use_mex = true;
options.contact_threshold = 0.02;
options.output_qdd = true;
options.solver = 1;
options.smooth_contacts = false;

if use_simple_pd
  if constrain_torso
    motion_frames = {lfoot_motion.getOutputFrame,rfoot_motion.getOutputFrame,pelvis_motion.getOutputFrame,torso_motion.getOutputFrame};
  else
    motion_frames = {lfoot_motion.getOutputFrame,rfoot_motion.getOutputFrame};
  end
  
  qp = MomentumControlBlock(r,motion_frames,ctrl_data,options);
  
  ins(1).system = 1;
  ins(1).input = 1;
  ins(2).system = 2;
  ins(2).input = 1;
  ins(3).system = 2;
  ins(3).input = 2;
  ins(4).system = 2;
  ins(4).input = 3;
  ins(5).system = 2;
  ins(5).input = 5;
  if constrain_torso
    ins(6).system = 2;
    ins(6).input = 6;
    ins(7).system = 2;
    ins(7).input = 7;
  end
  outs(1).system = 2;
  outs(1).output = 1;
  outs(2).system = 2;
  outs(2).output = 2;
  qp = mimoCascade(lfoot_motion,qp,[],ins,outs);
  clear ins;
  ins(1).system = 1;
  ins(1).input = 1;
  ins(2).system = 2;
  ins(2).input = 1;
  ins(3).system = 2;
  ins(3).input = 2;
  ins(4).system = 2;
  ins(4).input = 3;
  ins(5).system = 2;
  ins(5).input = 4;
  if constrain_torso
    ins(6).system = 2;
    ins(6).input = 6;
    ins(7).system = 2;
    ins(7).input = 7;
  end
  qp = mimoCascade(rfoot_motion,qp,[],ins,outs);
  if constrain_torso
    clear ins;
    ins(1).system = 1;
    ins(1).input = 1;
    ins(2).system = 2;
    ins(2).input = 1;
    ins(3).system = 2;
    ins(3).input = 2;
    ins(4).system = 2;
    ins(4).input = 3;
    ins(5).system = 2;
    ins(5).input = 4;
    ins(6).system = 2;
    ins(6).input = 5;
    ins(7).system = 2;
    ins(7).input = 7;
    qp = mimoCascade(pelvis_motion,qp,[],ins,outs);
    clear ins;
    ins(1).system = 1;
    ins(1).input = 1;
    ins(2).system = 2;
    ins(2).input = 1;
    ins(3).system = 2;
    ins(3).input = 2;
    ins(4).system = 2;
    ins(4).input = 3;
    ins(5).system = 2;
    ins(5).input = 4;
    ins(6).system = 2;
    ins(6).input = 5;
    ins(7).system = 2;
    ins(7).input = 6;
    qp = mimoCascade(torso_motion,qp,[],ins,outs);
  end
else
  qp = MomentumControlBlock(r,{},ctrl_data,options);
end
vo = VelocityOutputIntegratorBlock(r,options);
fcb = FootContactBlock(r);

% cascade IK/PD block
options.Kp = 40.0*ones(nq,1);
options.Kd = 12.0*ones(nq,1);
if use_simple_pd
  options.Kp(1:6) = 0; % ignore floating base
  options.Kd(1:6) = 0; % ignore floating base
  pd = SimplePDBlock(r,ctrl_data,options);
  ins(1).system = 1;
  ins(1).input = 1;
  ins(2).system = 1;
  ins(2).input = 2;
  ins(3).system = 2;
  ins(3).input = 1;
  ins(4).system = 2;
  ins(4).input = 2;
  ins(5).system = 2;
  ins(5).input = 3;
  if constrain_torso
    ins(6).system = 2;
    ins(6).input = 4;
    ins(7).system = 2;
    ins(7).input = 5;
    ins(8).system = 2;
    ins(8).input = 7;
  else
    ins(6).system = 2;
    ins(6).input = 5;
  end
else
  pd = IKPDBlock(r,ctrl_data,options);
  ins(1).system = 1;
  ins(1).input = 1;
  ins(2).system = 1;
  ins(2).input = 2;
  ins(3).system = 1;
  ins(3).input = 3;
  ins(4).system = 2;
  ins(4).input = 1;
  ins(5).system = 2;
  ins(5).input = 3;
end
outs(1).system = 2;
outs(1).output = 1;
outs(2).system = 2;
outs(2).output = 2;
qp_sys = mimoCascade(pd,qp,[],ins,outs);
clear ins;

toffset = -1;
tt=-1;

torque_fade_in = 0.1; % sec, to avoid jumps at the start

resp = input('OK to send input to robot? (y/n): ','s');
if ~strcmp(resp,{'y','yes'})
  return;
end

xtraj = [];

% low pass filter for floating base velocities
alpha_v = 0.5;
float_v = 0;

udes = zeros(nu,1);
qddes = zeros(nu,1);
qd_int_state = zeros(nq+4,1);
while tt<T
  [x,t] = getNextMessage(state_plus_effort_frame,1);
  if ~isempty(x)
    if toffset==-1
      toffset=t;
    end
    tt=t-toffset;
    tau = x(2*nq+(1:nq));

    % low pass filter floating base velocities
    float_v = (1-alpha_v)*float_v + alpha_v*x(nq+(1:6));
    x(nq+(1:6)) = float_v;
    
    xtraj = [xtraj x];
    q = x(1:nq);
    qd = x(nq+(1:nq));
 
    fc = output(fcb,tt,[],[q;qd]);
    
    x_filt = [q;qd];
    if use_simple_pd
      if constrain_torso
        u_and_qdd = output(qp_sys,tt,[],[q0; x_filt; x_filt; x_filt; x_filt; x_filt; x_filt; fc]);
      else
        u_and_qdd = output(qp_sys,tt,[],[q0; x_filt; x_filt; x_filt; x_filt; fc]);
      end
    else
      u_and_qdd = output(qp_sys,tt,[],[q0; x_filt; fc; x_filt; fc]);
    end
    u=u_and_qdd(1:nu);
    qdd=u_and_qdd(nu+(1:nq));

    qd_int_state = mimoUpdate(vo,tt,qd_int_state,x_filt,qdd,fc);
    qd_ref = mimoOutput(vo,tt,qd_int_state,x_filt,qdd,fc);

    % fade in desired torques to avoid spikes at the start
    udes(joint_act_ind) = u(joint_act_ind);
    tau = tau(act_idx_map);
    alpha = min(1.0,tt/torque_fade_in);
    udes(joint_act_ind) = (1-alpha)*tau(joint_act_ind) + alpha*udes(joint_act_ind);

    qddes(joint_act_ind) = qd_ref(joint_act_ind);

    ref_frame.publish(t,[q0(act_idx_map);qddes;udes],'ATLAS_COMMAND');
  end
end

disp('moving back to fixed point using position control.');
gains = getAtlasGains();
gains.k_f_p = zeros(nu,1);
gains.ff_f_d = zeros(nu,1);
gains.ff_qd = zeros(nu,1);
gains.ff_qd_d = zeros(nu,1);
ref_frame.updateGains(gains);

% move to fixed point configuration
qdes = xstar(1:nq);
atlasLinearMoveToPos(qdes,state_plus_effort_frame,ref_frame,act_idx_map,5);


% plot tracking performance
alpha = 0.1;
zmpact = [];
for i=1:size(xtraj,2)
  x = xtraj(:,i);
  q = x(1:nq);
  qd = x(nq+(1:nq));  
  
  if i==1
		qdd = 0*qd;
	else
		qdd = (1-alpha)*qdd_prev + alpha*(qd-qd_prev)/0.01;
  end
  qd_prev = qd;
	qdd_prev = qdd;  

  kinsol = doKinematics(r,q,false,true);
  [com,J] = getCOM(r,kinsol);
	J = J(1:2,:); 
	Jdot = forwardJacDot(r,kinsol,0);
  Jdot = Jdot(1:2,:);
	
	% hardcoding D for ZMP output dynamics
	D = -1.03./9.81*eye(2); 

	comdd = Jdot * qd + J * qdd;
	zmp = com(1:2) + D * comdd;
	zmpact = [zmpact [zmp;0]];
end

nb = length(zmptraj.getBreaks());
zmpknots = reshape(zmptraj.eval(zmptraj.getBreaks()),2,nb);
zmpknots = [zmpknots; zeros(1,nb)];

zmpact = R'*zmpact;
zmpknots = R'*zmpknots;

figure(11);
plot(zmpact(2,:),zmpact(1,:),'r');
hold on;
plot(zmpknots(2,:),zmpknots(1,:),'g');
hold off;
axis equal;

end
