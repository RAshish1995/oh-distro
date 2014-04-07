function make_bw(f,h,task,data_path,init_utime)
s.f =f
s.h =h
s.task = task
s.init_utime = init_utime


n= {'MAP_REQUEST', 'SENSOR_REQUEST', 'SUBIMAGE_REQUEST', 'CAMERA_SETTINGS', 'MAP_DEPTH_SETTINGS', 'COMMITTED_FOOTSTEP_PLAN', 'PMD_ORDERS', 'PMD_ORDERS2', 'DATA_REQUEST', 'COMMITTED_ROBOT_PLAN', 'COMMITTED_GRASP', 'AFFORDANCE_PLUS_BOT_OVERWRITE', 'GAZE_COMMAND', 'DESIRED_NECK_PITCH', 'SIMPLE_GRASP_COMMAND', 'COMMITTED_MANIP_GAIN', 'COMMITTED_POSTURE_PRESET', 'PMD_PRINTF_REQUEST', 'COMMITTED_PLAN_PAUSE', 'RECOVERY_CMD', 'COMMITTED_EE_ADJUSTMENT', 'CONTROLLER_MODE', 'MAP_CONTROLLER_COMMAND', 'COMMITTED_MANIP_MAP', 'MOTIONEST_REQUEST', 'STOP_WALKING', 'MULTISENSE_COMMAND', 'MAP_REQUEST_BBOX', 'IROBOT_LEFT_SIMPLE_GRASP', 'IROBOT_RIGHT_SIMPLE_GRASP', 'SANDIA_LEFT_SIMPLE_GRASP', 'SANDIA_RIGHT_SIMPLE_GRASP', 'IROBOT_RIGHT_CALIBRATE', 'IROBOT_RIGHT_SPREAD', 'IROBOT_RIGHT_POSITION_CONTROL_CLOSE', 'IROBOT_RIGHT_CURRENT_CONTROL_CLOSE', 'IROBOT_LEFT_CALIBRATE', 'IROBOT_LEFT_SPREAD', 'IROBOT_LEFT_POSITION_CONTROL_CLOSE', 'IROBOT_LEFT_CURRENT_CONTROL_CLOSE', 'ROBOTIQ_LEFT_COMMAND', 'ROBOTIQ_RIGHT_COMMAND', 'OGG_CLIENT', 'PLAN_USING_BDI_HEIGHT', 'ATLAS_BEHAVIOR_COMMAND', 'ATLAS_MANIPULATE_PARAMS', 'CALIBRATE_ARM_ENCODERS', 'RESET_DRIVER_SAFETY', 'BASE_UTIME'};
d= load ([data_path '/' task '/base_sent_data.txt']);
s.to_robot=1;
[results.to_robot.data, results.to_robot.time] = make_bw_dir(s,n,d);
  
  
n ={'CAMERA_LEFT_TX' 'CAMERA_RIGHT_TX' 'CAMERALHAND_LEFT_TX' 'CAMERARHAND_LEFT_TX' 'CAMERACHEST_LEFT_TX' 'CAMERACHEST_RIGHT_TX' 'CAMERA_LEFT_SUB' 'CAMERACHEST_LEFT_SUB' 'CAMERACHEST_RIGHT_SUB' 'MAP_OCTREE' 'MAP_CLOUD' 'MAP_DEPTH' 'OGG_SERVER' 'MAP_CATALOG' 'MAP_LOCAL_CORRECTION' 'SYSTEM_STATUS' 'POSE_TAG' 'AFFORDANCE_PLUS_BASE_OVERWRITE' 'PMD_PRINTF_REPLY' 'PMD_INFO2' 'FREQUENCY_LCM' 'ATLAS_STATUS' 'CONTROLLER_STATUS' 'EST_ROBOT_STATE'};
d = load ([data_path '/' task '/base_received_data.txt']);
s.to_robot=0;
[results.from_robot.data, results.from_robot.time] = make_bw_dir(s,n,d);


figure(f)
subplot(h)
hold on
plot( results.from_robot.time, results.from_robot.data,'b',...
   'LineWidth',2)
plot( results.to_robot.time, results.to_robot.data,'r',...
   'LineWidth',2)
set(gca,'YScale','log') 

set(gca,'YTick',[0, 1, 10, 100, 1000])
set(gca,'YTickLabel',{[0, 1, 10, 100, 1000]})
axis([0 30 0 1000])
xlabel('Time (Minutes)')

tlabel(1) = text(-3.5, 10,'Kbps sent to ...');%,'FontSize',18)
set( tlabel,'Rotation',90,'HorizontalAlignment','center');
tlabel(1) = text(-2.5, 1.5,'Robot','Color','r')
set( tlabel,'Rotation',90,'HorizontalAlignment','center');
tlabel(1) = text(-2.5, 150,'Operator','Color','b')
set( tlabel,'Rotation',90,'HorizontalAlignment','center');

box on

function [data_transmitted,time_transmitted] = make_bw_dir(s,n,d)

%  path = '';
  % log:
  %init_utime = 1387562271287314
  % mission:
%  init_utime = 1387562807870000


colors = [ 251/255.0, 154/255.0, 153/255.0;...
  178/255.0, 223/255.0, 138/255.0;...
  166/255.0, 206/255.0, 227/255.0;...
  51/255.0, 160/255.0, 44/255.0;...    
    31/255.0, 120/255.0, 180/255.0;...
    227/255.0, 26/255.0, 28/255.0;...
    253/255.0, 191/255.0, 111/255.0;...
    106/255.0, 61/255.0, 154/255.0;...
    255/255.0, 127/255.0, 0/255.0;...
    202/255.0, 178/255.0, 214/255.0;...
     51/255.0, 160/255.0, 44/255.0;...
    166/255.0, 206/255.0, 227/255.0;...
    178/255.0, 223/255.0, 138/255.0;...
    31/255.0, 120/255.0, 180/255.0;...
    251/255.0, 154/255.0, 153/255.0;...
    227/255.0, 26/255.0, 28/255.0;...
    253/255.0, 191/255.0, 111/255.0;...
    106/255.0, 61/255.0, 154/255.0;...
    255/255.0, 127/255.0, 0/255.0;...
    202/255.0, 178/255.0, 214/255.0;...
     51/255.0, 160/255.0, 44/255.0;...
    166/255.0, 206/255.0, 227/255.0;...
    178/255.0, 223/255.0, 138/255.0;...
    31/255.0, 120/255.0, 180/255.0;...
    251/255.0, 154/255.0, 153/255.0;...
    227/255.0, 26/255.0, 28/255.0;...
    253/255.0, 191/255.0, 111/255.0;...
    106/255.0, 61/255.0, 154/255.0;...
    255/255.0, 127/255.0, 0/255.0;...
    202/255.0, 178/255.0, 214/255.0;...
    1.0, 0.0, 0.0;...
    0.0, 1.0, 0.0;...
    0.0, 0.0, 1.0;...
    1.0, 1.0, 0.0;...
    1.0, 0.0, 1.0;...
    0.0, 1.0, 1.0;...
    0.5, 1.0, 0.0;...
    1.0, 0.5, 0.0;...
    0.5, 0.0, 1.0;...
    1.0, 0.0, 0.5;...
    0.0, 0.5, 1.0;...
    0.0, 1.0, 0.5;...
    1.0, 0.5, 0.5;...
    0.5, 1.0, 0.5;...
    0.5, 0.5, 1.0;...
    0.5, 0.5, 1.0;...
    0.5, 1.0, 0.5;...
    0.5, 0.5, 1.0]


for i=1:size(n,2)
  n{i} = strrep(n{i}, '_', ' ')
end





t = d(:,1);
d = d(:,2:end);

t =(t-s.init_utime)*1E-6;

mission_index = t > 0;
t =t(mission_index);
d =d(mission_index,:);

% remove data before run start
d = d - repmat(d(1,:) , size(d,1),1);
figure
plot(t, d)

idx = find (d(end,:)  > 500);
d_lots = d(:, idx );

win =30
for i=1:size(d_lots,2)
  % scale by 1000/8 to convert from Bytes to Kbps
  d_diff(:,i) =  diff(d_lots(1:win:end,i))/win /1000 * 8;
end
t_diff = [t(1:win:end)]
t_diff = t_diff(1:end-1)/60


figure
hold on


for i=1:size(d_lots,2)
    p(i)=plot(t,d_lots(:,i) ,'Color',colors(i,:),'LineWidth',5)
end
legend(p, n(idx))


figure
bar(t_diff,d_diff,1,'stack')
hold on

P=findobj(gca,'type','patch');
P=sort(P)
for n=1:length(P) 
  set(P(n),'facecolor',colors(n,:));
end


ylabel('Kbps')



data_transmitted = sum(d_diff');
time_transmitted = t_diff';