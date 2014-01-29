options.floating = true;
options.dt = 0.001;

warning('off','Drake:RigidBodyManipulator:UnsupportedContactPoints')
warning('off','Drake:RigidBodyManipulator:UnsupportedJointLimits')
warning('off','Drake:RigidBodyManipulator:UnsupportedVelocityLimits')
options.visual = false; % loads faster
r = Atlas(strcat(getenv('DRC_PATH'),'/models/mit_gazebo_models/mit_robot_drake/model_minimal_contact_point_hands.urdf'),options);
r = removeCollisionGroupsExcept(r,{'heel','toe'});
r = compile(r);

request = drc.footstep_plan_request_t();
request.utime = 0;

fp = load(strcat(getenv('DRC_PATH'), '/control/matlab/data/atlas_fp.mat'));
request.initial_state = r.getStateFrame().lcmcoder.encode(0, fp.xstar);

request.goal_pos = drc.position_3d_t();
request.goal_pos.translation = drc.vector_3d_t();
request.goal_pos.translation.x = 2.0;
request.goal_pos.translation.y = 0;
request.goal_pos.translation.z = 0;
request.goal_pos.rotation = drc.quaternion_t();
request.goal_pos.rotation.w = 1.0;
request.goal_pos.rotation.x = 0;
request.goal_pos.rotation.y = 0;
request.goal_pos.rotation.z = 0;

request.num_goal_steps = 0;

request.num_existing_steps = 1;
existing_steps = javaArray('drc.footstep_t', request.num_existing_steps);
existing_steps(1) = drc.footstep_t();
existing_steps(1).pos = drc.position_3d_t();
existing_steps(1).pos.translation = drc.vector_3d_t();
existing_steps(1).pos.translation.x = 0.2527;
existing_steps(1).pos.translation.y = 0.20;
existing_steps(1).pos.translation.z = 0;
existing_steps(1).pos.rotation = drc.quaternion_t();
existing_steps(1).pos.rotation.w = 1.0;
existing_steps(1).pos.rotation.x = 0;
existing_steps(1).pos.rotation.y = 0;
existing_steps(1).pos.rotation.z = 0;
existing_steps(1).id = 3;
existing_steps(1).is_right_foot = 0;
existing_steps(1).fixed_x = 1;
existing_steps(1).fixed_y = 1;
existing_steps(1).fixed_z = 1;
existing_steps(1).fixed_roll = 1;
existing_steps(1).fixed_pitch = 1;
existing_steps(1).fixed_yaw = 1;
request.existing_steps = existing_steps;

request.params = drc.footstep_plan_params_t();
request.params.max_num_steps = 10;
request.params.min_num_steps = 0;
request.params.min_step_width = 0.18;
request.params.nom_step_width = 0.26;
request.params.max_step_width = 0.35;
request.params.nom_forward_step = 0.2;
request.params.max_forward_step = 0.35;
request.params.ignore_terrain = true;
request.params.planning_mode = drc.footstep_plan_params_t.MODE_AUTO;
request.params.behavior = drc.footstep_plan_params_t.BEHAVIOR_BDI_STEPPING;
request.params.map_command = 0;
request.params.leading_foot = drc.footstep_plan_params_t.LEAD_LEFT;

request.default_step_params = drc.footstep_params_t();
request.default_step_params.utime = 0;
request.default_step_params.step_speed = 1.0;
request.default_step_params.step_height = 0.05;
request.default_step_params.bdi_step_duration = 0;
request.default_step_params.bdi_sway_duration = 0;
request.default_step_params.bdi_lift_height = 0;
request.default_step_params.bdi_toe_off = drc.atlas_behavior_step_action_t.TOE_OFF_ENABLE; 
request.default_step_params.bdi_knee_nominal = 0;
request.default_step_params.bdi_max_body_accel = 0;
request.default_step_params.bdi_max_foot_vel = 0;
request.default_step_params.bdi_sway_end_dist = 0.02;
request.default_step_params.bdi_step_end_dist = 0.02;
request.default_step_params.mu = 1.0;


p = StatelessFootstepPlanner();
plan = p.plan_footsteps(r, request);
plan.toLCM();
footsteps = plan.footsteps;
assert(footsteps(3).pos(2) == 0.20);
assert(length(footsteps) == 12);
assert(footsteps(3).infeasibility > 1e-6);
assert(footsteps(4).infeasibility > 1e-6);
assert(all([footsteps(5:end).infeasibility] < 1e-6))

request.num_goal_steps = 1;
goal_steps = javaArray('drc.footstep_t', request.num_goal_steps);
goal_steps(1) = drc.footstep_t();
goal_steps(1).pos = drc.position_3d_t();
goal_steps(1).pos.translation = drc.vector_3d_t();
goal_steps(1).pos.translation.x = 2.0;
goal_steps(1).pos.translation.y = -0.15;
goal_steps(1).pos.translation.z = 0;
goal_steps(1).pos.rotation = drc.quaternion_t();
goal_steps(1).pos.rotation.w = 1.0;
goal_steps(1).pos.rotation.x = 0;
goal_steps(1).pos.rotation.y = 0;
goal_steps(1).pos.rotation.z = 0;
goal_steps(1).id = -1;
goal_steps(1).is_right_foot = 1;
request.goal_steps = goal_steps;

plan = p.plan_footsteps(r, request);
footsteps = plan.footsteps;
s = Footstep.from_footstep_t(goal_steps(1));
assert(all(footsteps(end).pos == s.pos));

request.num_goal_steps = 3;
goal_steps = javaArray('drc.footstep_t', request.num_goal_steps);
goal_steps(1) = drc.footstep_t();
goal_steps(1).pos = drc.position_3d_t();
goal_steps(1).pos.translation = drc.vector_3d_t();
goal_steps(1).pos.translation.x = 2.0;
goal_steps(1).pos.translation.y = -0.15;
goal_steps(1).pos.translation.z = 0;
goal_steps(1).pos.rotation = drc.quaternion_t();
goal_steps(1).pos.rotation.w = 1.0;
goal_steps(1).pos.rotation.x = 0;
goal_steps(1).pos.rotation.y = 0;
goal_steps(1).pos.rotation.z = 0;
goal_steps(1).id = -1;
goal_steps(1).is_right_foot = 1;
goal_steps(2) = drc.footstep_t();
goal_steps(2).pos = drc.position_3d_t();
goal_steps(2).pos.translation = drc.vector_3d_t();
goal_steps(2).pos.translation.x = 2.1;
goal_steps(2).pos.translation.y = 0.1;
goal_steps(2).pos.translation.z = 0;
goal_steps(2).pos.rotation = drc.quaternion_t();
goal_steps(2).pos.rotation.w = 1.0;
goal_steps(2).pos.rotation.x = 0;
goal_steps(2).pos.rotation.y = 0;
goal_steps(2).pos.rotation.z = 0;
goal_steps(2).id = -1;
goal_steps(2).is_right_foot = 0;
goal_steps(3) = drc.footstep_t();
goal_steps(3).pos = drc.position_3d_t();
goal_steps(3).pos.translation = drc.vector_3d_t();
goal_steps(3).pos.translation.x = 2.2;
goal_steps(3).pos.translation.y = -0.15;
goal_steps(3).pos.translation.z = 0;
goal_steps(3).pos.rotation = drc.quaternion_t();
goal_steps(3).pos.rotation.w = 1.0;
goal_steps(3).pos.rotation.x = 0;
goal_steps(3).pos.rotation.y = 0;
goal_steps(3).pos.rotation.z = 0;
goal_steps(3).id = -1;
goal_steps(3).is_right_foot = 1;
request.goal_steps = goal_steps;

plan = p.plan_footsteps(r, request);
foosteps = plan.footsteps;
assert(length(footsteps) == 12)
assert(all([footsteps(1:2:end).is_right_foot] ~= [footsteps(2:2:end).is_right_foot]))

request.num_goal_steps = 3;
goal_steps = javaArray('drc.footstep_t', request.num_goal_steps);
goal_steps(1) = drc.footstep_t();
goal_steps(1).pos = drc.position_3d_t();
goal_steps(1).pos.translation = drc.vector_3d_t();
goal_steps(1).pos.translation.x = 2.0;
goal_steps(1).pos.translation.y = 0.1;
goal_steps(1).pos.translation.z = 0;
goal_steps(1).pos.rotation = drc.quaternion_t();
goal_steps(1).pos.rotation.w = 1.0;
goal_steps(1).pos.rotation.x = 0;
goal_steps(1).pos.rotation.y = 0;
goal_steps(1).pos.rotation.z = 0;
goal_steps(1).id = -1;
goal_steps(1).is_right_foot = 0;
goal_steps(2) = drc.footstep_t();
goal_steps(2).pos = drc.position_3d_t();
goal_steps(2).pos.translation = drc.vector_3d_t();
goal_steps(2).pos.translation.x = 2.1;
goal_steps(2).pos.translation.y = -0.15;
goal_steps(2).pos.translation.z = 0;
goal_steps(2).pos.rotation = drc.quaternion_t();
goal_steps(2).pos.rotation.w = 1.0;
goal_steps(2).pos.rotation.x = 0;
goal_steps(2).pos.rotation.y = 0;
goal_steps(2).pos.rotation.z = 0;
goal_steps(2).id = -1;
goal_steps(2).is_right_foot = 1;
goal_steps(3) = drc.footstep_t();
goal_steps(3).pos = drc.position_3d_t();
goal_steps(3).pos.translation = drc.vector_3d_t();
goal_steps(3).pos.translation.x = 2.2;
goal_steps(3).pos.translation.y = 0.1;
goal_steps(3).pos.translation.z = 0;
goal_steps(3).pos.rotation = drc.quaternion_t();
goal_steps(3).pos.rotation.w = 1.0;
goal_steps(3).pos.rotation.x = 0;
goal_steps(3).pos.rotation.y = 0;
goal_steps(3).pos.rotation.z = 0;
goal_steps(3).id = -1;
goal_steps(3).is_right_foot = 0;
request.goal_steps = goal_steps;

plan = p.plan_footsteps(r, request);
footsteps = plan.footsteps;
assert(mod(length(footsteps), 2) == 1)
assert(all([footsteps(1:2:end-1).is_right_foot] ~= [footsteps(2:2:end).is_right_foot]))
