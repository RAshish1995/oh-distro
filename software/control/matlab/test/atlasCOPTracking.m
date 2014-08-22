function atlasCOPTracking
%NOTEST
addpath(fullfile(getDrakePath,'examples','ZMP'));

r = Atlas();
r = removeCollisionGroupsExcept(r,{'toe','heel'});
r = compile(r);
load(strcat(getenv('DRC_PATH'),'/control/matlab/data/atlas_fp.mat'));
r = r.setInitialState(xstar);

% setup frames
state_frame = AtlasState(r);
state_frame.subscribe('EST_ROBOT_STATE');
ref_frame = AtlasPosVelTorqueRef(r);

nu = getNumInputs(r);
nq = getNumDOF(r);

act_idx_map = getActuatedJoints(r);
gains = getAtlasGains(); % change gains in this file

force_control_joint_str = {'leg'};% <---- cell array of (sub)strings  
force_controlled_joints = [];
for i=1:length(force_control_joint_str)
  force_controlled_joints = union(force_controlled_joints,find(~cellfun(@isempty,strfind(r.getInputFrame.coordinates,force_control_joint_str{i}))));
end

act_ind = (1:r.getNumInputs)';
position_controlled_joints = setdiff(act_ind,force_controlled_joints);

% zero out force gains to start --- move to nominal joint position
gains.k_f_p = zeros(nu,1);
gains.ff_f_d = zeros(nu,1);
gains.ff_qd = zeros(nu,1);
gains.ff_qd_d = zeros(nu,1);
ref_frame.updateGains(gains);

% move to fixed point configuration
qdes = xstar(1:nq);
atlasLinearMoveToPos(qdes,state_frame,ref_frame,act_idx_map,5);

gains_copy = getAtlasGains();
% reset force gains for joint being tuned
gains.k_f_p(force_controlled_joints) = gains_copy.k_f_p(force_controlled_joints);
gains.ff_f_d(force_controlled_joints) = gains_copy.ff_f_d(force_controlled_joints);
gains.ff_qd(force_controlled_joints) = gains_copy.ff_qd(force_controlled_joints);
gains.ff_qd_d(force_controlled_joints) = gains_copy.ff_qd_d(force_controlled_joints);
% set joint position gains to 0 for joint being tuned
gains.k_q_p(force_controlled_joints) = 0;
gains.k_q_i(force_controlled_joints) = 0;
gains.k_qd_p(force_controlled_joints) = 0;

ref_frame.updateGains(gains);

% get current state
[x,~] = getMessage(state_frame);
x0 = x(1:2*nq);
q0 = x0(1:nq);
kinsol = doKinematics(r,q0);

T = 10;
if 0
  % create figure 8 zmp traj
  dt = 0.01;
  ts = 0:dt:T;
  nt = T/dt;
  radius = 0.05; % 8 loop radius
  zmpx = [radius*sin(4*pi/T * ts(1:nt/2)), radius*sin(4*pi/T * ts(1:nt/2+1))];
  zmpy = [radius-radius*cos(4*pi/T * ts(1:nt/2)), -radius+radius*cos(4*pi/T * ts(1:nt/2+1))];
else
  % back and forth
  w=0.2;
  zmpx = [0 0  0 0  0 0  0 0  0 0];
  zmpy = [0 w -w w -w w -w w -w 0];

  np=length(zmpy);
  ts = linspace(0,T,np);

%   % rectangle
%   h=0.015; % height/2
%   w=0.08; % width/2
%   zmpx = [0 h h -h -h 0];
%   zmpy = [0 w -w -w w 0];
%   ts = [0 T/5 2*T/5 3*T/5 4*T/5 T];
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
[~,V,comtraj] = LinearInvertedPendulum.ZMPtrackerClosedForm(com(3)-zfeet,zmptraj,options);

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

foot_support = RigidBodySupportState(r,[rfoot_ind,lfoot_ind]);

pelvis_idx = findLinkInd(r,'pelvis');

link_constraints(1).link_ndx = pelvis_idx;
link_constraints(1).pt = [0;0;0];
link_constraints(1).traj = ConstantTrajectory(forwardKin(r,kinsol,pelvis_idx,[0;0;0],1));
link_constraints(2).link_ndx = rfoot_ind;
link_constraints(2).pt = [0;0;0];
link_constraints(2).traj = ConstantTrajectory(forwardKin(r,kinsol,rfoot_ind,[0;0;0],1));
link_constraints(3).link_ndx = lfoot_ind;
link_constraints(3).pt = [0;0;0];
link_constraints(3).traj = ConstantTrajectory(forwardKin(r,kinsol,lfoot_ind,[0;0;0],1));

ctrl_data = AtlasQPControllerData(true,struct(...
  'acceleration_input_frame',AtlasCoordinates(r),...
  'D',-getAtlasNominalCOMHeight()/9.81*eye(2),...
  'Qy',eye(2),...
  'S',V.S,...
  's1',V.s1,...
  's2',V.s2,...
  'x0',ConstantTrajectory([zmptraj.eval(zmptraj.tspan(2));0;0]),...
  'u0',ConstantTrajectory(zeros(2,1)),...
  'y0',zmptraj,...
  'qtraj',q0,...
  'support_times',0,...
  'supports',foot_support,...
  'mu',1.0,...
  'ignore_terrain',false,...
  'link_constraints',link_constraints,...
  'force_controlled_joints',force_controlled_joints,...
  'position_controlled_joints',position_controlled_joints,...
  'integral',zeros(getNumDOF(r),1),...
  'plan_shift',[0;0;0],...
  'constrained_dofs',[findJointIndices(r,'arm');findJointIndices(r,'back');findJointIndices(r,'neck')]));

sys = AtlasBalancingWrapper(r,ctrl_data,options);

toffset = -1;
tt=-1;

resp = input('OK to send input to robot? (y/n): ','s');
if ~strcmp(resp,{'y','yes'})
  return;
end

xtraj = [];
while tt<T
  [x,t] = getNextMessage(state_frame,1);
  if ~isempty(x)
    if toffset==-1
      toffset=t;
    end
    tt=t-toffset;
    xtraj = [xtraj,x];
    y = sys.output(tt,[],x);
    ref_frame.publish(t,y,'ATLAS_COMMAND');
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
atlasLinearMoveToPos(qdes,state_frame,ref_frame,act_idx_map,5);


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
