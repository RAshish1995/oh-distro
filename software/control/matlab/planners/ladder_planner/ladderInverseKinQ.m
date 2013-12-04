function Q = ladderInverseKinQ(r)
  cost = Point(r.getStateFrame,1);
  cost.base_x = 0;
  cost.base_y = 0;
  cost.base_z = 0;
  cost.base_roll = 1000;
  cost.base_pitch = 1000;
  cost.base_yaw = 1e2;
  cost.back_bkz = 1e4;
  cost.back_bky = 1e4;
  cost.back_bkx = 1e4;
%   cost.l_arm_usy = 1e1;
%   cost.r_arm_usy = 1e1;
  cost.l_arm_shx = 1e2;
  cost.r_arm_shx = 1e2;
  cost = double(cost);
  Q = diag(cost(1:r.getNumDOF));
end
