#include <iostream>
#include <fstream>
#include <Eigen/Dense>

#include "bot_lcmgl_client/lcmgl.h"

#include "capabilityMap/CapabilityMap.hpp"
#include "finalPosePlanner/FinalPosePlanner.hpp"
#include "drawingUtil/drawingUtil.hpp"

using namespace std;
using namespace Eigen;

int main()
{
	CapabilityMap cm("/home/marco/oh-distro/software/planning/capabilityMap.log");
	cm.loadFromMatlabBinFile("/home/marco/drc-testing-data/final_pose_planner/val_description/eigenexport_occ.bin");

	boost::shared_ptr<lcm::LCM> theLCM(new lcm::LCM);
	if(!theLCM->good()){
		std::cerr <<"ERROR: lcm is not good()" <<std::endl;
	}

	RigidBodyTree robot("/home/marco/oh-distro/software/models/val_description/urdf/valkyrie_sim_simple.urdf");
	std::vector<RigidBodyConstraint *> constraints;
	FinalPosePlanner fpp;

	VectorXd start_configuration;
	start_configuration.resize(robot.num_positions);
	start_configuration <<	0, 0, 1.0250, 0, 0 ,0 ,0, 0 ,0 ,0 ,0 ,0 ,0.3002,1.2500, 0, 0.7854, 1.5710 ,0, 0 ,0.3002, -1.2500,
			0, -0.7854, 1.5710 ,0, 0, 0, 0, -0.4900, 1.2050 ,-0.7100, 0 ,0, 0, -0.4900 ,1.2050, -0.7100 ,0;

	VectorXd endeffector_final_pose;
	endeffector_final_pose.resize(7);
	endeffector_final_pose << 0.8000, 0, 1.0625 ,0.7071 ,0 ,0 ,-0.7071;

	VectorXd nominal_configuration;
	nominal_configuration.resize(robot.num_positions);
	nominal_configuration <<	0, 0, 1.0250, 0, 0 ,0 ,0, 0 ,0 ,0 ,0 ,0 ,0.3002,1.2500, 0, 0.7854, 1.5710 ,0, 0 ,0.3002, -1.2500,
			0, -0.7854, 1.5710 ,0, 0, 0, 0, -0.4900, 1.2050 ,-0.7100, 0 ,0, 0, -0.4900 ,1.2050, -0.7100 ,0;

	string point_cloud_file = "/home/marco/drc-testing-data/final_pose_planner/scene1.bin";

	ifstream inputFile(point_cloud_file.c_str(), ifstream::binary);

	if (!inputFile.is_open())
	{
		std::cout << "Failed to open " << point_cloud_file.c_str() << '\n';
	}
	else
	{
		vector<Vector3d> point_cloud;
		unsigned int n_points;
		inputFile.read((char *) &n_points, sizeof(unsigned int));
		point_cloud.resize(n_points);
		for (int point = 0; point < n_points; point++)
		{
			inputFile.read((char *) point_cloud[point].data(), 3* sizeof(Vector3d::Scalar));
		}
		inputFile.close();

		bot_lcmgl_t* lcmgl_pc = bot_lcmgl_init(theLCM->getUnderlyingLCM(), "Point Cloud");
		drawPointCloud(lcmgl_pc, point_cloud);

		cm.setActiveSide("left");
		Vector3d endeffector_point = Vector3d(0.08, 0.07, 0);

		fpp.findFinalPose(robot, "leftPalm", "left", start_configuration, endeffector_final_pose, constraints, nominal_configuration , cm, point_cloud, IKoptions(&robot), theLCM, 0.005, endeffector_point);
		bot_lcmgl_t* lcmgl = bot_lcmgl_init(theLCM->getUnderlyingLCM(), "Capability map");
		cm.drawActiveMap(lcmgl, 52, Vector3d(0,0,0), false);
	}

	bot_lcmgl_t* lcmglOM = bot_lcmgl_init(theLCM->getUnderlyingLCM(), "Occupancy map");
	cm.drawOccupancyMap(lcmglOM, 16001, 52);

	return 0;
}
