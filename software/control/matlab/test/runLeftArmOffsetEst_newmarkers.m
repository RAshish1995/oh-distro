%NOTEST
if ~exist('r')
  r = Atlas(strcat(getenv('DRC_PATH'),'/models/mit_gazebo_models/mit_robot_drake/model_minimal_contact_point_hands.urdf'));
end
% logfile = strcat(getenv('DRC_PATH'),'/../logs/lcmlog-2013-10-02-vicon-test');
% logfile = strcat(getenv('DRC_PATH'),'/../logs/lcmlog-2013-10-07.00_right_arm_calib');

% logfile = strcat(getenv('DRC_PATH'),'/../logs/lcmlog-2013-10-09.00_right_arm_vicon_calibration');
% t_offset = -.56;

logfile = strcat(getenv('DRC_PATH'),'/../logs/lcmlog-2013-10-16.01');
t_offset = -.23;


[t_x,x_data,t_u,u_data,t_vicon,vicon_data,state_frame,input_frame,t_extra,extra_data,vicon_data_struct] = parseAtlasViconLog(r,logfile);
t_u = t_u - t_x(1);
t_vicon = t_vicon - t_x(1) + t_offset;  %%OFFSET TIME OF THE DATA! THIS MAY CHANGE
t_extra = t_extra - t_x(1);
t_x = t_x - t_x(1);

joint_indices = [10:14 21];
% joint_indices = [];
x0_offset = -extra_data(16+(1:6),1)+x_data(joint_indices((1:6)),1);
% hack to use encoder data
x_data_bkp = x_data;
for i=1:6,
  x_data(joint_indices(i),:) = unwrap(extra_data(16+i,:))+x0_offset(i);
end

% joint_indices = [33];

% Sample times
% todo, maybe filter the data around them?

% t_sample = [3 16 20.7 31 56.9 64.5];  
% t_sample  = [3 16 20.7 31 56.9 64.5 88.3 100.9];
% t_sample = [20.7 31 56.9 64.5 88.3 100.9 120 131.4 133.5 143.5 147.9 155.6];
% t_sample = [120 131.4 133.5 143.5 147.9 155.6];
% t_sample = [20.7];

%%
% t_sample = [2.5 9.8 22.5 27.4 38.5 47.5];
% t_sample = 9.8;
% t_sample = [9.8 38.5 45.7];
% t_sample = [2.5 9.8 22.5 38.5 47.5 71.5 83.4 93.4];

% for 10-16 data
t_sample = [421.8 449.7 474 502 548.8 574 609 650.1 683.9 725 741.9 772 797.4 823.6];

% torso_markers = reshape(vicon_data(21:40,:),4,5,length(t_vicon));
% hand_markers = reshape(vicon_data(1:20,:),4,5,length(t_vicon));
torso_markers = vicon_data_struct{6}.data;
hand_markers = vicon_data_struct{2}.data;

torso_markers(1:3,:,:) = torso_markers(1:3,:,:)/1e3;
hand_markers(1:3,:,:) = hand_markers(1:3,:,:)/1e3;


hand_markers = hand_markers - reshape(repmat([mean(mean(torso_markers(1:3,:,:),2),3);0],size(hand_markers,2)*size(hand_markers,3),1),4,size(hand_markers,2),[]);
torso_markers = torso_markers - reshape(repmat([mean(mean(torso_markers(1:3,:,:),2),3);0],size(torso_markers,2)*size(torso_markers,3),1),4,size(torso_markers,2),[]);

% %% change coordinates to make this a little easier
% --doesn't seem to really matter much
% tmp = hand_markers;
% hand_markers(1,:,:) = -tmp(3,:,:);
% hand_markers(2,:,:) = -tmp(1,:,:);
% hand_markers(3,:,:) =  tmp(2,:,:);
% 
% tmp = torso_markers;
% torso_markers(1,:,:) = -tmp(3,:,:);
% torso_markers(2,:,:) = -tmp(1,:,:);
% torso_markers(3,:,:) =  tmp(2,:,:);


torso_body = 5;
hand_body = 17;

clear q_data torso_data hand_data
% filter_len = 11;
% x_data = filter(ones(filter_len,1)/filter_len,1,x_data);
% torso_markers(1:3,:,:) = filter(ones(filter_len,1)/filter_len,1,torso_markers(1:3,:,:));
% hand_markers(1:3,:,:) = filter(ones(filter_len,1)/filter_len,1,hand_markers(1:3,:,:));

avg_range = 0;
for i=1:length(t_sample),
  ind_i = find(t_x > t_sample(i),1);
%   q_data(:,i) = x_data(1:34,ind_i);
  q_data(:,i) = mean(x_data(1:34,[ind_i-avg_range:ind_i+avg_range]),2);
  ind_i = find(t_vicon > t_sample(i),1);
%   torso_data(:,:,i) = torso_markers(1:3,:,ind_i);
%   hand_data(:,:,i) = hand_markers(1:3,:,ind_i);
  torso_data(:,:,i) = mean(torso_markers(1:3,:,[ind_i-avg_range:ind_i+avg_range]),3);
  hand_data(:,:,i) = mean(hand_markers(1:3,:,[ind_i-avg_range:ind_i+avg_range]),3);
  
  torso_obsc = find(sum(torso_markers(4,:,[ind_i-avg_range:ind_i+avg_range]),3));
  hand_obsc = find(sum(hand_markers(4,:,[ind_i-avg_range:ind_i+avg_range]),3));

  torso_data(:,torso_obsc,i) = NaN*torso_data(:,torso_obsc,i);
  hand_data(:,hand_obsc,i) = NaN*hand_data(:,hand_obsc,i);
end


%%
[dq, body1_params, body2_params, floating_states, residuals, info, J, body1_resids, body2_resids] = ...
  jointOffsetCalibration(r, q_data, joint_indices,torso_body,@(params) torsoMarkerPos_newmarkers(params,true), 0, torso_data, hand_body, @leftHandMarkerPos_newmarkers, 12, hand_data);
dq = unwrap([0;dq]);
dq = dq(2:end);
dq*180/pi

%%
v = r.constructVisualizer;
lcmgl = drake.util.BotLCMGLClient(lcm.lcm.LCM.getSingleton(),'bullet_collision_closest_points_test');
j = 1;
q = q_data(:,j);
% q(setdiff(1:34,joint_indices),:) = 0*q(setdiff(1:34,joint_indices),:);
% q = q*0;
q(1:6) = floating_states(:,j);

% b2 = [-.1 -.15 -.2 .1 -.1 .15]';
% b2 = body2_params;

% b2(2) = -.095 - .104;
q(joint_indices,1) = q(joint_indices,1) + dq;
% q(3) = q(3) + 1;
% q = q*0;
v.draw(0,q);
kinsol = r.doKinematics(q);
handpts = r.forwardKin(kinsol,hand_body,leftHandMarkerPos_newmarkers(body2_params));
torsopts = r.forwardKin(kinsol,torso_body,torsoMarkerPos_newmarkers(body1_params,true));
% 
for i=1:size(torso_markers,2),
  lcmgl.glColor3f(1,0,0); % red
  lcmgl.sphere(torsopts(:,i),.01,20,20);
  lcmgl.glColor3f(0,0,1); % blue
  lcmgl.sphere(torso_data(:,i,j),.01,20,20);
end

for i=1:size(hand_markers,2),
  lcmgl.glColor3f(1,0,0); % red
  lcmgl.sphere(handpts(:,i),.01,20,20);
  lcmgl.glColor3f(0,0,1); % blue
  lcmgl.sphere(hand_data(:,i,j),.01,20,20);
end
lcmgl.switchBuffers();

%%

% t_check = [3 16 20.7 31 56.9 64.5 88.3 100.9];
t_check = rand*max(t_vicon);
% t_check = [];
% t_check = 10;
qd_check = 1;
torso_check = 1;
hand_check = 1;
if length(t_check > 0) 
while max(max(abs(qd_check))) > .05 || any(any(isnan([torso_check(:);hand_check(:);q_check(:)])))
t_check = rand*max(t_vicon*.99);
% t_check = 42.9;
% t_check = [42.9 120 131.4 133.5 143.5 147.9 155.6];


clear q_check torso_check hand_check qd_check
for i=1:length(t_check),
  ind_i = find(t_x > t_check(i),1);
  
  q_check(:,i) = mean(x_data(1:34,[ind_i-avg_range:ind_i+avg_range]),2);
  qd_check(:,i) = mean(x_data(35:68,[ind_i-avg_range:ind_i+avg_range]),2);

  ind_i = find(t_vicon > t_check(i),1);
  %   torso_check(:,:,i) = torso_markers(1:3,:,ind_i);
  %   hand_check(:,:,i) = hand_markers(1:3,:,ind_i);
  torso_check(:,:,i) = mean(torso_markers(1:3,:,[ind_i-avg_range:ind_i+avg_range]),3);
  hand_check(:,:,i) = mean(hand_markers(1:3,:,[ind_i-avg_range:ind_i+avg_range]),3);
  
  torso_obsc = find(sum(torso_markers(4,:,[ind_i-avg_range:ind_i+avg_range]),3));
  hand_obsc = find(sum(hand_markers(4,:,[ind_i-avg_range:ind_i+avg_range]),3));
  
  torso_check(:,torso_obsc,i) = NaN*torso_check(:,torso_obsc,i);
  hand_check(:,hand_obsc,i) = NaN*hand_check(:,hand_obsc,i);  
end
q_check(joint_indices,:) = q_check(joint_indices,:) + repmat(dq,1,length(t_check));
q_check;
end

[~, ~, ~, floating_states_check, residual_check, info_check, J_check, body1_resids_check, body2_resids_check] = ...
  jointOffsetCalibration(r, q_check, [],torso_body,@(params) torsoMarkerPos_newmarkers(params,true), 0, torso_check, hand_body, @(params) leftHandMarkerPos_newmarkers(body2_params,true), 0, hand_check);


if length(t_check > 0)
v = r.constructVisualizer;
lcmgl = drake.util.BotLCMGLClient(lcm.lcm.LCM.getSingleton(),'bullet_collision_closest_points_test');
j = 1;
q = q_check(:,j);
% q(setdiff(1:34,joint_indices),:) = 0*q(setdiff(1:34,joint_indices),:);

q(1:6) = floating_states_check(:,j);
% q(2) = -.3;
% b2 = [-.1 -.15 -.2 .1 -.1 .15]';
b2 = body2_params;
% b2(2) = -.095;

q(joint_indices,1) = q(joint_indices,1);
v.draw(0,q);
kinsol = r.doKinematics(q);
handpts = r.forwardKin(kinsol,hand_body,leftHandMarkerPos_newmarkers(b2));
torsopts = r.forwardKin(kinsol,torso_body,torsoMarkerPos_newmarkers(body1_params,true));

for i=1:size(torso_markers,2),
  lcmgl.glColor3f(1,0,0); % red
  lcmgl.sphere(torsopts(:,i),.01,20,20);
  lcmgl.glColor3f(0,0,1); % blue
  lcmgl.sphere(torso_check(:,i,j),.01,20,20);
end

for i=1:size(hand_markers,2),
  lcmgl.glColor3f(1,0,0); % red
  lcmgl.sphere(handpts(:,i),.01,20,20);
  lcmgl.glColor3f(0,0,1); % blue
  lcmgl.sphere(hand_check(:,i,j),.01,20,20);
end
lcmgl.switchBuffers();
end
sprintf('mean err (mm): %d',mean(sqrt(sum(body2_resids_check.*body2_resids_check)))*1000)
end