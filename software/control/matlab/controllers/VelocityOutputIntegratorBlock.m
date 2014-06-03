classdef VelocityOutputIntegratorBlock < MIMODrakeSystem
  % integrates desired generalized accelerations and outputs a desired velocity
  %
  % input: x, qdd, foot_contact
  % state: [fc_left; fc_right; t_prev; lambda; qd_int]
  % output: qd_err (input frame)
  properties
		nq;
		r_ankle_idx;
		l_ankle_idx;
		leg_idx;
		act_idx_map;
  end
  
  methods
    function obj = VelocityOutputIntegratorBlock(r,options)
      typecheck(r,'Atlas');

      num_q = getNumDOF(r);
      input_frame = MultiCoordinateFrame({getStateFrame(r),AtlasCoordinates(r),FootContactState});
      output_frame = AtlasVelocityRef(r);      
      obj = obj@MIMODrakeSystem(0,4+num_q,input_frame,output_frame,true,true);
      obj = setInputFrame(obj,input_frame);
      obj = setOutputFrame(obj,output_frame);

      obj.nq = num_q;

      if nargin<2
        options = struct();
      end
                  
      if isfield(options,'dt')
        typecheck(options.dt,'double');
        sizecheck(options.dt,[1 1]);
        dt = options.dt;
      else
        dt = 0.001;
      end
      obj = setSampleTime(obj,[dt;0]); % sets controller update rate
      
			obj.r_ankle_idx = findJointIndices(r,'r_leg_ak');
			obj.l_ankle_idx = findJointIndices(r,'l_leg_ak');
			obj.leg_idx = findJointIndices(r,'leg');
			obj.act_idx_map = getActuatedJoints(r);
		end
   
    function y=mimoOutput(obj,~,state,varargin)
      x = varargin{1};
      qd = x(obj.nq+1:end);
			fc = varargin{3};
			
			l_foot_contact = fc(1);
			r_foot_contact = fc(2);
			
      % compute desired velocity
			qd_int = state(5:end);

			qd_err = qd_int-qd;

			% do not velocity control ankles when in contact
      if l_foot_contact>0.5
        qd_err(obj.l_ankle_idx)=0;
      end
      if r_foot_contact>0.5
        qd_err(obj.r_ankle_idx)=0;
      end
			
      delta_max = 1.0;
      y = max(-delta_max,min(delta_max,qd_err(obj.act_idx_map)));
		end
		
		function next_state=mimoUpdate(obj,t,state,varargin)
      x = varargin{1};
      qd = x(obj.nq+1:end);
			qdd = varargin{2};
			fc = varargin{3};

			l_foot_contact = fc(1);
			r_foot_contact = fc(2);

 			eta = state(4);

			qd_int = state(5:end);
			dt = t-state(3);
			
			qd_int = ((1-eta)*qd_int + eta*qd) + qdd*dt; 
			
      if l_foot_contact>0.5
        qd_int(obj.l_ankle_idx)=0;
      end
      if r_foot_contact>0.5
        qd_int(obj.r_ankle_idx)=0;
      end

			next_state = state;
			next_state(1) = fc(1);
			next_state(2) = fc(2);
			next_state(3) = t;

      eta = max(0.0,eta-dt); % linear ramp
%       if state(1)~=l_foot_contact || state(2)~=r_foot_contact
%         % contact state changed, reset integrated velocities
%         qd_int(obj.leg_idx) = qd(obj.leg_idx);
% %         eta = 0.3; % decay integrated velocity to actual
%       end
      next_state(4) = eta;
			next_state(5:end) = qd_int;
		end
	end
  
end