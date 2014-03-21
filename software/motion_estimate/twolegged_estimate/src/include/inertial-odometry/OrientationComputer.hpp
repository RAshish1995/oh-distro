/*
 * OrientationComputer.hpp
 *
 *  Created on: May 31, 2013
 *      Author: dehann fourie
 */

#ifndef ORIENTATIONCOMPUTER_HPP_
#define ORIENTATIONCOMPUTER_HPP_


#include <leg-odometry/SignalTap.hpp>
#include <leg-odometry/QuaternionLib.h>
#include <inertial-odometry/InertialOdometry_Types.hpp>

namespace InertialOdometry {

class OrientationComputer {
private:
	Eigen::Quaterniond lQb;
	unsigned long long latest_uts;

	Eigen::Vector3d prevWb;

public:
	EIGEN_MAKE_ALIGNED_OPERATOR_NEW

	OrientationComputer();

	// force the quaternion, for if we have one
	void updateOrientation(const unsigned long long &uts, const Eigen::Quaterniond &set_to_q);

	// We compute the quaternion ourselves
	void updateOrientationWithAngle(const unsigned long long &uts, const Eigen::Vector3d &delta_ang);
	void updateOrientationWithRate(const unsigned long long &uts, const Eigen::Vector3d &w_b);

	// Adjust the orientation estimate with a know rotational quantity
	void rotateOrientationUpdate(const Eigen::Vector3d &_dE_l);

	Eigen::Vector3d ResolveBodyToRef(const Eigen::Vector3d &vec_b);
	void updateOutput(InertialOdomOutput &_out);
	Eigen::Quaterniond q();

	//void exmap(const Eigen::Vector3d &w_k0, Eigen::Matrix3d &R);// exmap for quaternion is in QuaternionLib

	Eigen::Matrix3d vec2skew(const Eigen::Vector3d &v);
    void setYaw(const double &yaw);
};

}

#endif /* ORIENTATIONCOMPUTER_HPP_ */
