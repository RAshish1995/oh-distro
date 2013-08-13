


declare -a sim_joints=(back_ubx
back_lbz
back_mby
neck_ay
l_leg_lax
l_leg_uay
l_leg_mhx
l_leg_lhy
l_leg_uhz
l_leg_kny
r_leg_lax
r_leg_uay
r_leg_mhx
r_leg_lhy
r_leg_uhz
r_leg_kny
l_arm_elx
l_arm_ely
l_arm_shx
l_arm_usy
l_arm_mwx
l_arm_uwy
r_arm_elx
r_arm_ely
r_arm_shx
r_arm_usy
r_arm_mwx
r_arm_uwy )


declare -a bdi_joints=(back_bkx
back_bky
back_bkz
neck_ry
l_leg_akx
l_leg_aky
l_leg_hpx
l_leg_hpy
l_leg_hpz
l_leg_kny
r_leg_akx
r_leg_aky
r_leg_hpx
r_leg_hpy
r_leg_hpz
r_leg_kny
l_arm_elx
l_arm_ely
l_arm_shx
l_arm_shy
l_arm_wrx
l_arm_wry
r_arm_elx
r_arm_ely
r_arm_shx
r_arm_shy
r_arm_wrx
r_arm_wry )

n_joints=${#bdi[@]}
echo $n_joints


#sed 's/l_leg_lax/l_leg_akx/g' <model.urdf > model_sim.urdf

#${sim[@]}
cp model.urdf model_sim.urdf

for (( i=0; i<${n_joints}; i++ ));
do
  strfrom=${sim_joints[$i]}
  strto=${bdi_joints[$i]}
  echo "$i | from $strfrom | to $strto"
  pattern='s/'"$strfrom"'/'"$strto"'/g'
  #pattern='s/neck_ay/random/g'
  echo $pattern
  sed -i $pattern model_sim.urdf 
done