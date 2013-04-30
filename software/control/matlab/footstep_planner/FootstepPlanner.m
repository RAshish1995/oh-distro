classdef FootstepPlanner < DRCPlanner
  properties
    biped
    monitors
    hmap_ptr
    options
  end
  
  methods
    function obj = FootstepPlanner(biped)
      typecheck(biped, 'Biped');
      
      robot_name = 'atlas';
      obj = obj@DRCPlanner();
      % obj = obj@DRCPlanner('NAV_GOAL_TIMED',JLCMCoder(NavGoalCoder(robot_name)));
      obj.biped = biped;

      obj = addInput(obj,'goal', 'WALKING_GOAL', 'drc.walking_goal_t', 1, 1, 1);
      obj = addInput(obj,'x0','EST_ROBOT_STATE',obj.biped.getStateFrame().lcmcoder,true,true);
      obj = addInput(obj, 'plan_con', 'FOOTSTEP_PLAN_CONSTRAINT', drc.footstep_plan_t(), false, true);
      obj = addInput(obj, 'plan_commit', 'COMMITTED_FOOTSTEP_PLAN', drc.footstep_plan_t(), false, true);
      obj = addInput(obj, 'plan_reject', 'REJECTED_FOOTSTEP_PLAN', drc.footstep_plan_t(), false, true);
      obj.hmap_ptr = mapAPIwrapper();
      % mapAPIwrapper(obj.hmap_ptr);
    end

    function X = updatePlan(obj, X, data, changed, changelist, heightfun)
      if changelist.goal || isempty(X)
        msg ='Footstep Planner: Received Goal Info'; disp(msg); send_status(3,0,0,msg);
        for x = {'max_num_steps', 'min_num_steps', 'timeout', 'time_per_step', 'yaw_fixed', 'is_new_goal', 'right_foot_lead'}
          obj.options.(x{1}) = data.goal.(x{1});
        end
        obj.options.time_per_step = obj.options.time_per_step / 1e9;
        obj.options.timeout = obj.options.timeout / 1e6;
      end
      if (changelist.goal && (data.goal.is_new_goal || ~data.goal.allow_optimization)) || isempty(X)
        msg ='Footstep Planner: Received New Goal'; disp(msg); send_status(3,0,0,msg);
        goal_pos = [data.goal.goal_pos.translation.x;
                    data.goal.goal_pos.translation.y;
                    data.goal.goal_pos.translation.z];
        [goal_pos(4), goal_pos(5), goal_pos(6)] = quat2angle([data.goal.goal_pos.rotation.w,...
                                          data.goal.goal_pos.rotation.x,...
                                          data.goal.goal_pos.rotation.y,...
                                          data.goal.goal_pos.rotation.z], 'XYZ');
        [X, foot_goals] = obj.biped.createInitialSteps(data.x0, goal_pos, obj.options, heightfun);
      end
      if changelist.plan_con
        new_X = FootstepPlanListener.decodeFootstepPlan(data.plan_con);
        new_X = new_X(1);
        new_X.pos = obj.biped.footOrig2Contact(new_X.pos, 'center', new_X.is_right_foot);
        new_X.pos(3) = new_X.pos(3) + 0.003; % add back the 3mm we subtracted before publishing
        X([X.id] == new_X.id) = new_X;
        t = num2cell(obj.biped.getStepTimes([X.pos]));
        [X.time] = t{:};
      end

      for j = 1:size(X, 2)
        if X(j).is_in_contact
          X(j).pos = heightfun(X(j).pos);
        end
      end
    end

    
    function X = plan(obj,data)
      X_old = [];
      goal_pos = [];
      obj.options = struct();
      last_publish_time = now();
      isnew = true;

      foot_body = struct('right', findLink(obj.biped, obj.biped.r_foot_name),...
                            'left', findLink(obj.biped, obj.biped.l_foot_name));

      while 1
        [data, changed, changelist] = obj.updateData(data);
        isnew = changelist.goal || isempty(X_old);
        if changelist.plan_reject 
          msg ='Footstep Planner: Rejected'; disp(msg); send_status(3,0,0,msg);
          break;
        end
        if changelist.plan_commit
          msg ='Footstep Planner: Committed'; disp(msg); send_status(3,0,0,msg);
        end
        X = obj.updatePlan(X_old, data, changed, changelist, @heightfun);

        if isequal(size(X_old), size(X)) && all(all(abs([X_old.pos] - [X.pos]) < 0.01))
          modified = false;
        else
          modified = true;
        end
        X_old = X;

        if modified || ((now() - last_publish_time) * 24 * 60 * 60 > 1)
          Xout = X;
          % Convert from foot center to foot origin
          for j = 1:length(X)
            Xout(j).pos = obj.biped.footContact2Orig(X(j).pos, 'center', X(j).is_right_foot);
            % move the planned steps down by 3mm (helps with force classification and compensates for gazebo issues)
            Xout(j).pos(3) = Xout(j).pos(3) - 0.003;
          end
          publish(Xout);
          last_publish_time = now();
        else
          pause(1)
        end
      end


      function publish(X)
        obj.biped.publish_footstep_plan(X, data.utime, isnew);
      end

      function [ground_pos, got_data, terrain_ok, ground_pts] = heightfun(pos, is_right_foot)
        if nargin < 2
          is_right_foot = -1;
        end
        orig = obj.biped.footContact2Orig(pos, 'center', is_right_foot);

        if is_right_foot ~= -1
          sizecheck(pos, [6, 1]);
          if is_right_foot
            gc = foot_body.right.contact_pts;
          else
            gc = foot_body.left.contact_pts;
          end
          for j = 1:length(gc(1,:))
            M = makehgtform('xrotate', orig(4), 'yrotate', orig(5), 'zrotate', orig(6));
            offs = gc(:,j) * 1.1;
            d = M * [offs; 1];
            gc(:,j) = orig(1:3) + d(1:3);
          end
          [ground_pts, normals] = mapAPIwrapper(obj.hmap_ptr, [gc, pos(1:3,:)]);
          plot_lcm_points(ground_pts', zeros(length(gc(1,:))+1,3), 100, 'contact pts', 1, 1);
          max_z_dist = max(ground_pts(3,:)) - min(ground_pts(3,:));
          if any(any(isnan(ground_pts)))
            terrain_ok = false;
            got_data = false;
          else
            if max_z_dist < 0.005
              terrain_ok = true;
            else
              coeff = princomp(ground_pts');
              plane_normal = coeff(:,3)';
              cosines = [];
              for j = 1:length(normals)
                cosines(end+1) = dot(normals(:,j), plane_normal) / (norm(normals(:,j)) * norm(plane_normal));
              end
              err = abs((ground_pts' - repmat(mean(ground_pts,2)',size(ground_pts, 2),1))*plane_normal');
              terrain_ok = all(abs(cosines) > cos(10*pi/180)) && all(err < 0.01);
            end
          end
        else
          ground_pts = [0];
          terrain_ok = 0;
        end

        [closest_terrain_pos, normal] = mapAPIwrapper(obj.hmap_ptr, pos(1:3,:));
        costheta = dot(normal, [0;0;1]) / norm(normal);
        terrain_ok = terrain_ok && abs(costheta) > cos(30*pi/180);
        
        % h = zeros(1, length(pos(1,:)));
        ground_pos = pos;
        if ~any(isnan(closest_terrain_pos))
          ground_pos(1:3) = closest_terrain_pos;
          ax = cross([0;0;1], normal);
          theta = -acos(costheta);
          q = axis2quat([ax;theta]);
          new_rpy = quat2rpy(q);
          if ~any(isnan(new_rpy))
            ground_pos(4:5) = new_rpy(1:2);
          end
        end
        got_data = ~any(isnan(closest_terrain_pos)) && ~any(any(isnan(ground_pts)));
        % ground_pos(3,:) = h;
      end
    end
  end
end


