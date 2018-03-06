__author__ = 'manuelli'

from director import visualization as vis
from director.debugVis import DebugData
import director.objectmodel as om
from director import lcmUtils
from director import transformUtils
import bot_core
import drc as lcmdrc
import drake as lcmdrake

import numpy as np
import yaml

# some useful constants
EPSILON = 0.1
EPSILON_CONTACT_FORCE = 3.0

class ForceVisualizer:

    def __init__(self, robotSystem, view, configFilename):

        self.robotStateModel = robotSystem.robotStateModel
        self.robotStateJointController = robotSystem.robotStateJointController
        self.robotSystem = robotSystem
        self.view = view


        self.leftInContact = 0
        self.rightInContact = 0
        self.footContactEstimateMsg = None
        self.initializeOptions()
        self.loadConfig(configFilename)

        # they are hidden by default
        d = DebugData()
        visObj = vis.updatePolyData(d.getPolyData(), self.options['estForceVisName'], view=self.view, parent='robot state model')
        visObj.setProperty('Visible', False)

        visObj = vis.updatePolyData(d.getPolyData(), self.options['pelvisAccelerationVisName'], view=self.view, parent='robot state model')
        visObj.setProperty('Visible', False)

        visObj = vis.updatePolyData(d.getPolyData(), self.options['copVisName'], view=self.view, parent='robot state model')
        visObj.setProperty('Visible', False)

        visObj = vis.updatePolyData(d.getPolyData(), self.options['QPForceVisName'], view=self.view, parent='robot state model')
        visObj.setProperty('Visible', False)

        visObj = vis.updatePolyData(d.getPolyData(), self.options['contactPointsVisName'], view=self.view, parent='robot state model')
        visObj.setProperty('Visible', False)

        visObj = vis.updatePolyData(d.getPolyData(), self.options['desiredCOPVisName'], view=self.view, parent='robot state model')
        visObj.setProperty('Visible', False)

        visObj = vis.updatePolyData(d.getPolyData(), self.options['desiredCOMVisName'], view=self.view, parent='robot state model')
        visObj.setProperty('Visible', True)

        visObj = vis.updatePolyData(d.getPolyData(), self.options['actualCOMVisName'], view=self.view, parent='robot state model')
        visObj.setProperty('Visible', True)


        self.visObjDict = dict()
        self.visObjDict['bodyMotion'] = vis.updatePolyData(d.getPolyData(), self.options['bodyMotionVisName'], view=self.view, parent='robot state model')
        self.visObjDict['bodyMotion'].setProperty('Visible', False)
        self.addSubscribers()


        # setup a dict to keep track of the names we will need
        # probably want to store this in a config file so it can work with Atlas as well as Val
        lFootDict = {}
        lFootDict['visName'] = 'l_foot_force_est'

        rFootDict = {}
        rFootDict['visName'] = 'r_foot_force_est'

        # special logic for handling FT frames. Valkyrie's is just specified as a named frame in the urdf
        # for Atlas it is just the foot frame
        if (self.config['robotType'] == 'Atlas'):
            lFootDict['FT_frame_id'] = self.robotStateModel.model.findLinkID(self.config['leftFoot']['linkName'])
            rFootDict['FT_frame_id'] = self.robotStateModel.model.findLinkID(self.config['rightFoot']['linkName'])

        elif (self.config['robotType'] == 'Valkyrie'):
            lFootDict['FT_frame_id'] = self.robotStateModel.model.findFrameID(self.config['leftFoot']['forceTorqueFrameName'])
            rFootDict['FT_frame_id'] = self.robotStateModel.model.findFrameID(self.config['rightFoot']['forceTorqueFrameName'])

        else:
            raise ValueError('robotType in config file must be either Atlas or Valkyrie')



        self.nameDict = {}
        self.nameDict['l_foot'] = lFootDict
        self.nameDict['r_foot'] = rFootDict

        # changes for getting this to work on Atlas
        # Everything coming from the QP should be able to stay the same.
        # The foot names and force/torque frames are probably different
        # Also contact points are different, but I think these come from the QP directly
        # so they should be ok

    def initializeOptions(self):
        self.options = {}
        self.options['speedLimit'] = 20 # speed limit on redrawing
        # self.options['forceMagnitudeNormalizer'] = 600
        self.options['forceArrowLength'] = 0.4
        self.options['forceArrowTubeRadius'] = 0.01
        self.options['forceArrowHeadRadius'] = 0.03
        self.options['forceArrowColor'] = [1,0,0]
        self.options['estForceVisName'] = 'meas foot forces'
        self.options['pelvisAccelerationVisName'] = 'desired pelvis acceleration'
        self.options['pelvisMagnitudeNormalizer'] = 2.0
        self.options['pelvisArrowLength'] = 0.8
        self.options['QPForceVisName'] = 'QP foot force'
        self.options['bodyMotionVisName'] = 'Body Motion Data'
        self.options['contactPointsVisName'] = 'Contact Points'

        self.options['copVisName'] = 'meas cop'
        self.options['desiredCOPVisName'] = 'desired cop'
        self.options['desiredCOMVisName'] = 'desired com'
        self.options['actualCOMVisName'] = 'com actual'

        self.options['colors'] = dict()
        self.options['colors']['plan'] = [1,0,0] # red
        self.options['colors']['plannedZMP'] = [1,1,0] # yellow
        self.options['colors']['plannedCOM'] = [245/255.0,145/255.0,0] # orange
        self.options['colors']['actualCOM'] = [1,0,0] # red
        self.options['colors']['controller'] = [0,0,1] # blue
        self.options['colors']['measured'] = [0,1,0] # green
        self.options['colors']['contactPoints'] = [ 0.58039216,  0, 0.82745098] # purple



    def loadConfig(self, configFilename):
        stream = file(configFilename)
        self.config = yaml.load(stream)

    def addSubscribers(self):

        # FORCE_TORQUE subscriber
        # draws measured foot forces, cop etc

        # force torque message has different names on Atlas and Val
        # problem, this isn't published for Atlas, all the info is inside EST_ROBOT_STATE
        self.forceTorqueSubscriber = lcmUtils.addSubscriber("FORCE_TORQUE", bot_core.six_axis_force_torque_array_t,
                                                                self.onForceTorqueMessage)

        self.forceTorqueSubscriber.setSpeedLimit(self.options['speedLimit'])

        # draw
        self.controllerStateSubscriber = lcmUtils.addSubscriber("CONTROLLER_STATE", lcmdrc.controller_state_t, self.onControllerStateMessage)
        self.controllerStateSubscriber.setSpeedLimit(self.options['speedLimit'])

        # foot contact estimate
        sub = lcmUtils.addSubscriber('FOOT_CONTACT_ESTIMATE', lcmdrc.foot_contact_estimate_t, self.onFootContactEstimateMsg)
        sub.setSpeedLimit(self.options['speedLimit'])

        # desiredCOP
        sub = lcmUtils.addSubscriber('QP_CONTROLLER_INPUT', lcmdrake.lcmt_qp_controller_input, self.extractDesiredCOP)
        sub.setSpeedLimit(self.options['speedLimit'])

        # desiredCOM
        sub = lcmUtils.addSubscriber('PLAN_EVAL_DEBUG', lcmdrc.plan_eval_debug_t, self.onPlanEvalDebug)
        sub.setSpeedLimit(self.options['speedLimit'])

        # alternate thing for getting force-torque info from EST_ROBOT_STATE
        # sub = lcmUtils.addSubscriber('EST_ROBOT_STATE', bot_core.robot_state_t, self.onEstRobotState)
        # sub.setSpeedLimit(self.options['speedLimit'])




    # msg is six_axis_force_torque_array_t
    def onForceTorqueMessage(self, msg):

        if (om.findObjectByName(self.options['estForceVisName']).getProperty('Visible') and self.robotStateJointController.lastRobotStateMessage):
            d = DebugData()

            for idx, sensorName in enumerate(msg.names):
                sensorName = str(sensorName)

                # only draw the forces for feet sensors, i.e. ignore hands etc.
                if sensorName in self.nameDict:
                    self.drawFootForce(sensorName, msg.sensors[idx], d)

            vis.updatePolyData(d.getPolyData(), name=self.options['estForceVisName'], view=self.view,
                               parent='robot state model').setProperty('Color', self.options['colors']['measured'])


        if (om.findObjectByName(self.options['copVisName']).getProperty('Visible') and self.robotStateJointController.lastRobotStateMessage):
            copInWorld, d = self.computeCOP(msg)
            vis.updatePolyData(d.getPolyData(), name=self.options['copVisName'], view=self.view,
                           parent='robot state model').setProperty('Color', self.options['colors']['measured'])


    def onEstRobotState(self, msg):


        if ( not (om.findObjectByName(self.options['estForceVisName']).getProperty('Visible') or
         om.findObjectByName(self.options['copVisName']).getProperty('Visible')) ):
            return


        # basically just recreate force torque msg
        forceTorqueMsg = bot_core.six_axis_force_torque_array_t()
        forceTorqueMsg.num_sensors = 2
        forceTorqueMsg.names = ['l_foot', 'r_foot']

        leftFootMsg = bot_core.six_axis_force_torque_t()
        rightFootMsg = bot_core.six_axis_force_torque_t()

        leftFootMsg.force = np.array([msg.force_torque.l_foot_force_x, msg.force_torque.l_foot_force_y, msg.force_torque.l_foot_force_z])
        leftFootMsg.moment = np.array([msg.force_torque.l_foot_torque_x, msg.force_torque.l_foot_torque_y, msg.force_torque.l_foot_torque_z])

        rightFootMsg.force = np.array([msg.force_torque.r_foot_force_x, msg.force_torque.r_foot_force_y, msg.force_torque.r_foot_force_z])
        rightFootMsg.moment = np.array([msg.force_torque.r_foot_torque_x, msg.force_torque.r_foot_torque_y, msg.force_torque.r_foot_torque_z])

        forceTorqueMsg.sensors = [leftFootMsg, rightFootMsg]

        self.onForceTorqueMessage(forceTorqueMsg)

    def onPlanEvalDebug(self, msg):
        if (om.findObjectByName(self.options['desiredCOMVisName']).getProperty('Visible')):
            self.drawDesiredCOM(msg)


    # here msg is six_axis_force_torque_t
    def drawFootForce(self, footName, msg, debugData):
        force = np.array(msg.force)
        forceNorm = np.linalg.norm(force)
        scaledForce = self.options['forceArrowLength']/self.config['ForceMagnitudeNormalizer']*force
        torque = np.array(msg.moment)

        visName = self.nameDict[footName]['visName']
        ftFrameId = self.nameDict[footName]['FT_frame_id']

        ftFrameToWorld = self.robotStateModel.getFrameToWorld(ftFrameId)

        forceStartInWorld = ftFrameToWorld.TransformPoint((0,0,0))
        forceEndInWorld = np.array(ftFrameToWorld.TransformPoint(scaledForce))

        debugData.addArrow(forceStartInWorld, forceEndInWorld, tubeRadius=self.options['forceArrowTubeRadius'],
                           headRadius=self.options['forceArrowHeadRadius'], color=self.options['colors']['measured'])


    def drawQPContactWrench(self, msg):
        # draw the contact wrenches
        d = DebugData()
        copData = dict()
        totalForce = np.zeros(3)
        for contact_output in msg.contact_output:
            footName = contact_output.body_name
            ftFrameId = 0
            ftFrameToWorld = 0
            if (footName == 'leftFoot' or footName == 'l_foot'):
                footName = "left"
                ftFrameId = self.nameDict['l_foot']['FT_frame_id']
                ftFrameToWorld = self.robotStateModel.getFrameToWorld(ftFrameId)
            elif (footName == 'rightFoot' or footName == 'r_foot'):
                footName = "right"
                ftFrameId = self.nameDict['r_foot']['FT_frame_id']
                ftFrameToWorld = self.robotStateModel.getFrameToWorld(ftFrameId)


            # this wrench is really expressed at ref_point. Since we want this to match with the FT frame we draw it at
            # that point instead
            #arrowStart = np.array((msg.contact_ref_points[i][0], msg.contact_ref_points[i][1], msg.contact_ref_points[i][2]))
            arrowStart = ftFrameToWorld.TransformPoint((0,0,0))
            force = np.array((contact_output.wrench[3], contact_output.wrench[4], contact_output.wrench[5]))

            # skip if the force is pretty small
            if (np.linalg.norm(force) < EPSILON):
                continue

            arrowEnd = arrowStart + self.options['forceArrowLength']/self.config['ForceMagnitudeNormalizer']*force

            d.addArrow(arrowStart, arrowEnd, tubeRadius=self.options['forceArrowTubeRadius'],
                           headRadius=self.options['forceArrowHeadRadius'], color=self.options['colors']['controller'])

            # compute cop
            # this is already in world frame
            cop = np.zeros(3)
            cop[0] = -contact_output.wrench[1] / contact_output.wrench[5] + contact_output.ref_point[0]
            cop[1] = contact_output.wrench[0] / contact_output.wrench[5] + contact_output.ref_point[1]
            cop[2] = contact_output.ref_point[2]

            totalForce += np.array((contact_output.wrench[3],contact_output.wrench[4],contact_output.wrench[5]))

            data = dict()
            data['cop'] = cop
            data['fz'] = contact_output.wrench[5]
            copData[footName] = data

            # this is the individual foot COP coming from the QP
            # project it down to the bottom of the foot
            singleFootCOP = cop + self.config['FOOT_FRAME_TO_SOLE_DIST']/force[2]*force
            d.addSphere(singleFootCOP, radius=0.01)

        cop = np.zeros(3)
        totalForceMag = 0
        for key, val in copData.iteritems():
            totalForceMag += val['fz']

        for key, val in copData.iteritems():
            cop += val['cop']*val['fz']/totalForceMag


        # need to project down to the base of the foot basically
        if(np.abs(totalForce[2]) > 0.01):
            cop += self.config['FOOT_FRAME_TO_SOLE_DIST']/totalForce[2]*totalForce

        d.addSphere(cop, radius=0.015)
        vis.updatePolyData(d.getPolyData(), name=self.options['QPForceVisName'], view=self.view,
                               parent='robot state model').setProperty('Color', self.options['colors']['controller'])


    def drawQPContactPointsAndForces(self, msg, drawContactPoints=True, drawContactForces=False):

        d = DebugData()

        # everything is in world frame, so shouldn't need to do too much to draw it
        for contact_output in msg.contact_output:
            footName = contact_output.body_name
            ftFrameId = 0
            ftFrameToWorld = 0
            if (footName == 'leftFoot' or footName == 'l_foot'):
                footName = "left"
                ftFrameId = self.nameDict['l_foot']['FT_frame_id']
                ftFrameToWorld = self.robotStateModel.getFrameToWorld(ftFrameId)
            elif (footName == 'rightFoot' or footName == 'r_foot'):
                footName = "right"
                ftFrameId = self.nameDict['r_foot']['FT_frame_id']
                ftFrameToWorld = self.robotStateModel.getFrameToWorld(ftFrameId)


            contactPointArray = np.array(contact_output.contact_points)
            contactForceArray = np.array(contact_output.contact_forces)

            for idx in xrange(0, contact_output.num_contact_points):
                contactPointInWorld = contactPointArray[idx,:]
                contactForceInWorld = contactForceArray[idx,:]

                if drawContactPoints:
                    d.addSphere(contactPointInWorld, radius=0.01, color=self.options['colors']['contactPoints'])

                if drawContactForces and np.linalg.norm(contactForceInWorld > EPSILON_CONTACT_FORCE):
                    arrowStart = contactPointInWorld
                    arrowEnd = arrowStart + self.options['forceArrowLength']/self.config['ForceMagnitudeNormalizer']*contactForceInWorld

                    d.addArrow(arrowStart, arrowEnd, tubeRadius=self.options['forceArrowTubeRadius'],
                               headRadius=self.options['forceArrowHeadRadius'], color=self.options['colors']['controller'])

        vis.updatePolyData(d.getPolyData(), name=self.options['contactPointsVisName'], view=self.view,
                           parent=' robot state model').setProperty('Color', self.options['colors']['contactPoints'])

    # draw the acceleration of the pelvis that the QP thinks is happening
    def onControllerStateMessage(self, msg):

        if (om.findObjectByName(self.options['pelvisAccelerationVisName']).getProperty('Visible') and self.robotStateJointController.lastRobotStateMessage):

            pelvisJointNames = ['base_x', 'base_y', 'base_z']
            pelvisAcceleration = np.zeros(3)

            for idx, name in enumerate(pelvisJointNames):
                stateIdx = msg.joint_name.index(name)
                pelvisAcceleration[idx] = msg.qdd[stateIdx]


            pelvisFrame = self.robotStateModel.getLinkFrame('pelvis')

            arrowStart = np.array(pelvisFrame.TransformPoint((0,0,0)))
            arrowEnd = arrowStart + self.options['pelvisArrowLength']*np.linalg.norm(pelvisAcceleration)/self.options['pelvisMagnitudeNormalizer']*pelvisAcceleration

            debugData = DebugData()
            debugData.addArrow(arrowStart, arrowEnd, tubeRadius=self.options['forceArrowTubeRadius'],
                               headRadius=self.options['forceArrowHeadRadius'])

            vis.updatePolyData(debugData.getPolyData(), name=self.options['pelvisAccelerationVisName'], view=self.view,
                               parent='robot state model').setProperty('Color', self.options['colors']['controller'])

        if (om.findObjectByName(self.options['QPForceVisName']).getProperty('Visible') and self.robotStateJointController.lastRobotStateMessage):
            self.drawQPContactWrench(msg)


        if (om.findObjectByName(self.options['bodyMotionVisName']).getProperty('Visible')):
            self.drawBodyMotionData(msg.desired_body_motions)


        if (om.findObjectByName(self.options['contactPointsVisName']).getProperty('Visible') and self.robotStateJointController.lastRobotStateMessage):
            self.drawQPContactPointsAndForces(msg, drawContactPoints=True, drawContactForces=True)


        # print "got controller state message"
        # print "pelvisAcceleration ", pelvisAcceleration
        # print "arrowStart ", arrowStart
        # print "arrowEnd ", arrowEnd


    # computes the COP from the force torque measurement???
    def computeCOP(self, msg):
        d = DebugData()
        copDataList = []
        for idx, sensorName in enumerate(msg.names):
            sensorName = str(sensorName)
            if sensorName in self.nameDict:
                copDataList.append(self.computeSingleFootCOP(sensorName, msg.sensors[idx], d))

        copInWorld = (copDataList[0]['cop']*copDataList[0]['fz'] + copDataList[1]['cop']*copDataList[1]['fz'])/(
            copDataList[0]['fz'] + copDataList[1]['fz'])

        d.addSphere(copInWorld, radius=0.015)


        return copInWorld, d


    def computeSingleFootCOP(self, footName, msg, d):

        force = np.array(msg.force)
        # hack for dealing with very small fz.
        if np.linalg.norm(force) < 0.001:
            force[2] = 0.001


        x = -msg.moment[1]/force[2]
        y = msg.moment[0]/force[2]
        alpha = self.config['FT_FRAME_TO_SOLE_DIST']/force[2]

        cop = np.array((x,y,0))
        cop = cop + alpha*force

        ftFrameId = self.nameDict[footName]['FT_frame_id']
        ftFrameToWorld = self.robotStateModel.getFrameToWorld(ftFrameId)

        copInWorld = np.array(ftFrameToWorld.TransformPoint(cop))

        d.addSphere(copInWorld, radius=0.01)

        copData = {'cop': copInWorld, 'fz': np.linalg.norm(force)}
        return copData

    def drawMeasuredCOM(self):
        d = DebugData()
        com = np.array(self.robotStateModel.model.getCenterOfMass())
        com[2] = self.getAverageFootHeight();
        d.addSphere(com, radius=0.015)

        vis.updatePolyData(d.getPolyData(), name=self.options['actualCOMVisName'], view=self.view,
                               parent='robot state model').setProperty('Color', self.options['colors']['actualCOM'])



    # record which foot is in contact
    def onFootContactEstimateMsg(self, msg):
        self.footContactEstimateMsg = msg

        if (om.findObjectByName(self.options['actualCOMVisName']).getProperty('Visible')):
            self.drawMeasuredCOM()


    # get current average foot height
    def getAverageFootHeight(self):
        if self.footContactEstimateMsg is None:
            return 0
        footNames = ['l_foot', 'r_foot']
        footContact = np.array([self.footContactEstimateMsg.left_contact, self.footContactEstimateMsg.right_contact])
        avgFootHeight = 0

        for idx, name in enumerate(footNames):
            ftFrameId = self.nameDict[name]['FT_frame_id']
            ftFrameToWorld = self.robotStateModel.getFrameToWorld(ftFrameId)

            solePoint = ftFrameToWorld.TransformPoint((0,0,self.config['FT_FRAME_TO_SOLE_DIST']))
            soleHeight = solePoint[2]
            avgFootHeight += footContact[idx]*soleHeight

        if np.sum(footContact) > 0.1:
            avgFootHeight = avgFootHeight/np.sum(footContact)
        else:
            avgFootHeight = 0

        return avgFootHeight

    # computes the desired COP location coming from the qp_input message
    def extractDesiredCOP(self, qpInputMsg):
        if (om.findObjectByName(self.options['desiredCOPVisName']).getProperty('Visible')):
            y0 = qpInputMsg.zmp_data.y0
            desiredCOP = np.zeros(3)
            desiredCOP[0] = y0[0][0]
            desiredCOP[1] = y0[1][0]
            desiredCOP[2] = self.getAverageFootHeight()


            d = DebugData()
            d.addSphere(desiredCOP, radius=0.015)

            vis.updatePolyData(d.getPolyData(), name=self.options['desiredCOPVisName'], view=self.view,
                               parent='robot state model').setProperty('Color', self.options['colors']['plannedZMP'])


    # msg should be a plan eval debug message
    def drawDesiredCOM(self, msg):

        com_des = np.zeros(3)
        com_des[0:2] = np.array(msg.com_des)
        com_des[2] = self.getAverageFootHeight()

        d = DebugData()
        # boxDim = 0.03*np.ones(3)
        # d.addCube(boxDim, com_des)

        d.addSphere(com_des, radius=0.015)

        vis.updatePolyData(d.getPolyData(), name=self.options['desiredCOMVisName'], view=self.view,
                               parent='robot state model').setProperty('Color', self.options['colors']['plannedCOM'])

    # takes in a qp_desired_body_motion_t message
    def drawBodyMotionData(self, desired_body_motions):
        # first remove all existing frames
        childFrames = self.visObjDict['bodyMotion'].children()
        for frame in childFrames:
            om.removeFromObjectModel(frame)

        # add new frames for tracked bodies
        for bodyMotionData in desired_body_motions:
            bodyName = bodyMotionData.body_name
            frameName = bodyName + ' body motion'
            position = bodyMotionData.body_q_d[0:3]
            rpy = bodyMotionData.body_q_d[3:6]
            frame = transformUtils.frameFromPositionAndRPY(position, rpy)
            vis.showFrame(frame, frameName, view=self.view, parent=self.options['bodyMotionVisName'], scale=0.2)



























