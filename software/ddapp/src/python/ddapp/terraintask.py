import os
import sys
import vtkAll as vtk
from ddapp import botpy
import math
import time
import types
import functools
import numpy as np
from collections import defaultdict

from ddapp import transformUtils
from ddapp import lcmUtils
from ddapp.timercallback import TimerCallback
from ddapp.asynctaskqueue import AsyncTaskQueue
from ddapp import objectmodel as om
from ddapp import visualization as vis
from ddapp import applogic as app
from ddapp.debugVis import DebugData
from ddapp import ikplanner
from ddapp import ioUtils
from ddapp.simpletimer import SimpleTimer
from ddapp.utime import getUtime
from ddapp import affordanceitems
from ddapp import robotstate
from ddapp import robotplanlistener
from ddapp import segmentation
from ddapp import planplayback
from ddapp import affordanceupdater
from ddapp import segmentationpanel
from ddapp import footstepsdriver
from ddapp import footstepsdriverpanel

from ddapp.footstepsdriver import FootstepRequestGenerator

import ddapp.terrain

from ddapp.tasks.taskuserpanel import TaskUserPanel
from ddapp.tasks.taskuserpanel import ImageBasedAffordanceFit

import ddapp.tasks.robottasks as rt
import ddapp.tasks.taskmanagerwidget as tmw

import drc as lcmdrc
import copy
import re

from PythonQt import QtCore, QtGui



blockWidth = (15 + 3/8.0) * 0.0254
blockLength = (15 + 5/8.0) * 0.0254
blockHeight = (5 + 5/8.0) * 0.0254
blockDiagonal = np.linalg.norm([blockWidth, blockLength, blockHeight])

blockSafetyMargin = [0.03, 0.05]

class TerrainTask(object):

    def __init__(self, robotSystem):
        self.robotSystem = robotSystem
        self.cinderblockPrefix = 'cinderblock'
        self.stairPrefix = 'stair'

        self.currentRow = {'left':-1, 'right':-1}
        self.stanceBlocks = {'left':None, 'right':None}
        self.useTextures = False
        self.constrainBlockSize = True
        self.blockFitAlgo = 1

        self.timer = TimerCallback(targetFps=30)
        self.timer.callback = self.updateBlockState


    def startBlockUpdater(self):
        self.timer.start()


    def stopBlockUpdater(self):
        self.timer.stop()


    def requestRaycastTerrain(self):
        affs = self.robotSystem.affordanceManager.getCollisionAffordances()
        xy = self.robotSystem.robotStateJointController.q[:2]
        self.robotSystem.raycastDriver.requestRaycast(affs, xy-4.5, xy+4.5)


    def walkToTiltedCinderblocks(self):
        frame = om.findObjectByName('cinderblock stance frame')
        assert frame

        frameCopy = transformUtils.copyFrame(frame.transform)
        footstepsdriverpanel.panel.onNewWalkingGoal(frameCopy)

    def requestBlockFit(self):
        msg = lcmdrc.block_fit_request_t()
        msg.utime = getUtime()
        if self.constrainBlockSize:
            msg.dimensions = [blockLength, blockWidth, blockHeight]
        else:
            msg.dimensions = [0, 0, blockHeight]
        msg.name_prefix = 'cinderblock'
        msg.algorithm = self.blockFitAlgo
        lcmUtils.publish('BLOCK_FIT_TRIGGER', msg)

    def spawnGroundAffordance(self):

        polyData = segmentation.getCurrentRevolutionData()
        groundOrigin, normal, groundPoints, _ = segmentation.segmentGround(polyData)

        stanceFrame = FootstepRequestGenerator.getRobotStanceFrame(self.robotSystem.robotStateModel)
        origin = np.array(stanceFrame.GetPosition())

        origin = segmentation.projectPointToPlane(origin, groundOrigin, normal)

        zaxis = normal
        xaxis = transformUtils.getAxesFromTransform(stanceFrame)[0]

        yaxis = np.cross(zaxis, xaxis)
        yaxis /= np.linalg.norm(yaxis)
        xaxis = np.cross(yaxis, zaxis)
        xaxis /= np.linalg.norm(xaxis)

        boxThickness = 0.01

        t = transformUtils.getTransformFromAxes(xaxis, yaxis, zaxis)
        t.PreMultiply()
        t.Translate(0.0, 0.0, -boxThickness/2.0)
        t.PostMultiply()
        t.Translate(origin)

        om.removeFromObjectModel(om.findObjectByName('ground affordance'))
        pose = transformUtils.poseFromTransform(t)
        desc = dict(classname='BoxAffordanceItem', Name='ground affordance', Dimensions=[10, 10, boxThickness], pose=pose)
        aff = segmentation.affordanceManager.newAffordanceFromDescription(desc)
        aff.setProperty('Visible', False)
        aff.setProperty('Alpha', 0.2)


    def getPlanningStartPose(self):
        return self.robotSystem.robotStateJointController.q.copy()

    def spawnTiltedCinderblocks(self):

        for obj in self.getCinderblockAffordances():
            om.removeFromObjectModel(obj)

        stanceFrame = FootstepRequestGenerator.getRobotStanceFrame(self.robotSystem.robotStateModel)
        stanceFrame.PreMultiply()
        stanceFrame.Translate(0.25, 0.0, 0.0)

        f = vis.showFrame(stanceFrame, 'cinderblock stance frame', scale=0.2)
        frameSync = vis.FrameSync()
        frameSync.addFrame(f)
        f.frameSync = frameSync

        startPose = self.robotSystem.robotStateJointController.q.copy()

        forwardOffset = 0.25

        relativeFrame = transformUtils.frameFromPositionAndRPY([0.0, blockWidth/2.0, 0.0], [0.0, 0.0, 0.0])
        relativeFrame.PostMultiply()
        relativeFrame.Concatenate(stanceFrame)

        self.spawnTiltedCinderblocksRow(relativeFrame, startSequence=0, numberOfBlocks=4)

        relativeFrame = transformUtils.frameFromPositionAndRPY([0.0, -blockWidth/2.0, 0.0], [0.0, 0.0, 0.0])
        relativeFrame.PostMultiply()
        relativeFrame.Concatenate(stanceFrame)

        self.spawnTiltedCinderblocksRow(relativeFrame, startSequence=3, numberOfBlocks=4)

        for block in self.getCinderblockAffordances():
            frameSync.addFrame(block.getChildFrame(), ignoreIncoming=True)

    def getBoxAffordancesWithNamePrefix(self, prefix):

        affs = []
        for obj in om.getObjects():
            if isinstance(obj, affordanceitems.BoxAffordanceItem) and obj.getProperty('Name').startswith(prefix):
                affs.append(obj)

        return sorted(affs, key=lambda x: x.getProperty('Name'))

    def getStairAffordances(self):
        return self.getBoxAffordancesWithNamePrefix(self.stairPrefix)

    def getCinderblockAffordances(self):
        return self.getBoxAffordancesWithNamePrefix(self.cinderblockPrefix)

    def getAffordanceDistanceToFrame(self, affordance, frame):
        return np.linalg.norm(affordance.getChildFrame().transform.GetPosition() - np.array(frame.GetPosition()))

    def sortAffordancesByDistanceToFrame(self, affordances, frame):
        dists = [self.getAffordanceDistanceToFrame(aff, frame) for aff in affordances]
        return [affordances[i] for i in np.argsort(dists)]

    def getAffordanceClosestToFoot(self, affordances, side):
        '''
        Given a list of affordances and string 'left' or 'right', returns
        the affordance closest to the foot frame.  Also returns the foot frame
        and the distance between foot and affordance frames.
        '''
        linkName = {'left':'l_foot', 'right':'r_foot'}[side]
        footFrame = self.getFootFrameAtSole(linkName)

        vis.updateFrame(footFrame, 'foot frame ' + side, scale=0.2, visible=False)

        aff = self.sortAffordancesByDistanceToFrame(affordances, footFrame)[0]
        return aff, footFrame, self.getAffordanceDistanceToFrame(aff, footFrame)


    def getCinderblockUnderFoot(self, side):
        affordances = self.getCinderblockAffordances()
        if not affordances:
            return None

        aff, footFrame, distance = self.getAffordanceClosestToFoot(affordances, side)

        blockFrame = transformUtils.copyFrame(aff.getChildFrame().transform)

        footToBlock = transformUtils.concatenateTransforms([footFrame, blockFrame.GetLinearInverse()])

        xyz = footToBlock.GetPosition()


        #d = DebugData()
        #d.addLine(blockFrame.GetPosition(), footFrame.GetPosition(), color=self.getFootColor(side))
        #vis.updatePolyData(d.getPolyData(), 'foot to block debug %s' % side, colorByName='RGB255')

        if not (-blockHeight*0.5 < xyz[2] < blockHeight):
            return None

        #print 'xyz:', xyz
        #print 'max xy offset:', max([abs(xyz[0]), abs(xyz[1])])
        #print 'max block dim:', max([blockLength/2, blockWidth/2])

        if max(abs(xyz[0]), abs(xyz[1])) > max(blockLength/2.0, blockWidth/2.0):
            return None

        return aff


    def getFootColor(self, side):
        if side == 'left':
            return footstepsdriver.getLeftFootColor()
        else:
            return footstepsdriver.getRightFootColor()


    def getBlockRowColumn(self, blockAffordance):
        return [int(s) for s in re.findall('\d+', blockAffordance.getProperty('Name'))]

    def sideToFootLinkName(self, side):
        return {'left':'l_foot', 'right':'r_foot'}[side]

    def sideToColumn(self, side):
        return ['right', 'left'].index(side)

    def columnToSide(self, column):
        return ['right', 'left'][column]


    def getRearBlocks(self, side):
        row = self.currentRow[side]
        column = self.sideToColumn(side)
        blocks = []
        for block in self.getCinderblockAffordances():
            r, c = self.getBlockRowColumn(block)
            if c == column and r < row:
                blocks.append(block)
        return blocks


    def getCinderblockAffordances(self):
        blocks = []
        for obj in om.getObjects():
            name = obj.getProperty('Name')
            if re.match('^%s \(\d,\d\)$' % self.cinderblockPrefix, name):
                blocks.append(obj)

        return blocks

    def getFitCinderblockAffordances(self):

        blocks = []
        for obj in om.getObjects():
            name = obj.getProperty('Name')
            if re.match('^%s \d$' % self.cinderblockPrefix, name):
                blocks.append(obj)

        return blocks


    def organizeFitBlocks(self):

        self.updateBlockState()

        blocks = self.getFitCinderblockAffordances()

        if not blocks:
            return

        # rename with temp name
        originalPrefix = self.cinderblockPrefix
        tempPrefix = 'temp_%s' % originalPrefix
        self.cinderblockPrefix = tempPrefix

        for i, block in enumerate(blocks):
            name = '%s %d' % (tempPrefix, i)
            block.rename(name)

        # reorient, sort and rename
        self.reorientBlocks(blocks)
        self.sortAndRenameBlocks(blocks)

        # remove blocks under the feet or behind the robot
        for side in ['left', 'right']:
            if not self.stanceBlocks[side]:
                continue

            nearBlock = self.getCinderblockUnderFoot(side)
            om.removeFromObjectModel(nearBlock)
            for block in self.getRearBlocks(side):
                om.removeFromObjectModel(block)

        # add current row to names and remove temp name
        blocks = self.getCinderblockAffordances()
        if blocks:

            minRow = min([self.getBlockRowColumn(block)[0] for block in blocks])

            for block in blocks:
                r, c = self.getBlockRowColumn(block)
                side = self.columnToSide(c)
                newRow = (r - minRow) + self.currentRow[side] + 1
                block.rename('%s (%d,%d)' % (originalPrefix, newRow , c))

        self.cinderblockPrefix = originalPrefix
        self.updateBlockState()

    def getFrontBlocks(self, side):
        row = self.currentRow[side]
        column = self.sideToColumn(side)
        blocks = []
        for block in self.getCinderblockAffordances():
            r, c = self.getBlockRowColumn(block)
            if c == column and r > row:
                blocks.append(block)
        return blocks


    def hideRearBlocks(self, side):
        for block in self.getRearBlocks(side):
            block.setProperty('Alpha', 0.1)

    def textureFrontBlocks(self, side):
        for block in self.getFrontBlocks(side):
            block.setProperty('Camera Texture Enabled', True)

    def highlightStanceBlock(self, side):
        block = self.stanceBlocks[side]
        if block:
            block.setProperty('Color', self.getFootColor(side))

    def resetBlockRows(self):
        for side in ['left', 'right']:
            self.currentRow[side] = -1
            self.stanceBlocks[side] = None

    def updateCurrentBlockRow(self, side):

        block = self.getCinderblockUnderFoot(side)
        self.stanceBlocks[side] = block

        if not block:
            return False

        blockRow, blockColumn = self.getBlockRowColumn(block)

        if blockColumn != self.sideToColumn(side):
            print 'matched wrong block for side %s %s' % (side, block.getProperty('Name'))
            return False

        if blockRow > self.currentRow[side]:
            self.currentRow[side] = blockRow
            return True
        return False


    def deleteFrontBlocks(self):

        self.updateBlockState()

        for side in ['left', 'right']:
            for block in self.getFrontBlocks(side):
                om.removeFromObjectModel(block)

    def updateBlockState(self):

        self.resetCinderblockVisualizationProperties()

        for side in ['left', 'right']:
            self.updateCurrentBlockRow(side)
            self.hideRearBlocks(side)
            self.highlightStanceBlock(side)

            if self.useTextures:
                self.textureFrontBlocks(side)


    def getCinderblockAffordanceWithRowColumn(self, row, column):
        name = '%s (%d,%d)' % (self.cinderblockPrefix, row, column)
        return om.findObjectByName(name)


    def spawnFootstepsForCinderblocks(self):

        def flipSide(side):
            return 'right' if side == 'left' else 'left'


        leadingFoot = 'right'

        if self.currentRow[flipSide(leadingFoot)] < self.currentRow[leadingFoot]:
            leadingFoot = flipSide(leadingFoot)


        stepFrames = []

        sideToRow = dict(self.currentRow)
        nextSide = leadingFoot

        om.removeFromObjectModel(om.findObjectByName('debug step frames'))

        while True:

            side = nextSide
            nextSide = flipSide(side)
            row = sideToRow[side] + 1
            sideToRow[side] = row

            #print '------------------------'
            #print 'step side:', side
            #print 'step row:', row

            block = self.getCinderblockAffordanceWithRowColumn(row, self.sideToColumn(side))
            neighborBlock = self.getCinderblockAffordanceWithRowColumn(row, self.sideToColumn(flipSide(side)))
            if not block or not neighborBlock:
                break

            d = np.array(block.getProperty('Dimensions'))/2.0
            t = transformUtils.copyFrame(block.getChildFrame().transform)

            yOffset = 0.09
            xOffset = 0.05
            yOffsetSign = -1 if side == 'left' else 1
            xOffsetSign = -1 if side == leadingFoot else 1

            stepOffset = [xOffset*xOffsetSign, yOffset*yOffsetSign]

            pt = stepOffset[0], stepOffset[1], d[2]
            t.PreMultiply()
            t.Translate(pt)
            stepFrames.append(t)

            #obj = vis.showFrame(t, '%s step frame' % block.getProperty('Name'), parent='step frames', scale=0.2)


        startPose = self.getPlanningStartPose()

        helper = FootstepRequestGenerator(self.robotSystem.footstepsDriver)
        request = helper.makeFootstepRequest(startPose, stepFrames, leadingFoot, snapToTerrain=True)

        self.robotSystem.footstepsDriver.sendFootstepPlanRequest(request, waitForResponse=True)


    def printCinderblocksUnderFoot(self):

        for side in ['left', 'right']:
            block = self.getCinderblockUnderFoot(side)
            print side, block.getProperty('Name') if block else None


    def getFootstepObjects(self):
        folder = om.findObjectByName('footstep plan')
        if not folder:
            return []
        steps = []
        for obj in folder.children():
            if re.match('^step \d$', obj.getProperty('Name')):
                steps.append(obj)
        return steps


    def printFootstepOffsets(self):

        blocks = self.getCinderblockAffordances()
        steps = self.getFootstepObjects()

        for step in steps:
            stepFrame = step.getChildFrame().transform

            block = self.sortAffordancesByDistanceToFrame(blocks, stepFrame)[0]
            print '%s  --> %s' % (step.getProperty('Name'), block.getProperty('Name'))


    def resetCinderblockVisualizationProperties(self):
        for obj in self.getCinderblockAffordances():

            obj.setProperty('Alpha', 1.0)
            obj.setProperty('Camera Texture Enabled', False)
            if not self.useTextures:
                obj.setProperty('Color', [0.8, 0.8, 0.8])

    def reorientBlocks(self, blocks):

        stanceFrame = FootstepRequestGenerator.getRobotStanceFrame(self.robotSystem.robotStateModel)
        forward = transformUtils.getAxesFromTransform(stanceFrame)[0]

        for block in blocks:

            blockFrame = block.getChildFrame().transform
            axes = transformUtils.getAxesFromTransform(blockFrame)
            origin = blockFrame.GetPosition()
            axes = [np.array(axis) for axis in axes]
            dims = block.getProperty('Dimensions')
            axisIndex, axis, sign = transformUtils.findTransformAxis(blockFrame, forward)
            if axisIndex == 2:
                continue

            if axisIndex == 0 and sign < 0:
                axes = [-axes[0], -axes[1], axes[2]]
            elif axisIndex == 1:
                dims = [dims[1], dims[0], dims[2]]
                if sign > 0:
                    axes = [axes[1], -axes[0], axes[2]]
                else:
                    axes = [-axes[1], axes[0], axes[2]]

            t = transformUtils.getTransformFromAxesAndOrigin(axes[0], axes[1], axes[2], origin)
            block.getChildFrame().copyFrame(t)
            block.setProperty('Dimensions', dims)

    def sortAndRenameBlocks(self, blocks):
        """
        Sort the blocks into row and column bins using the robot's stance frame, and rename the accordingly
        """
        if not blocks:
            return

        blockDescriptions = [block.getDescription() for block in blocks]

        blockRows = defaultdict(lambda: [])

        stanceFrame = FootstepRequestGenerator.getRobotStanceFrame(self.robotSystem.robotStateModel)
        T = stanceFrame.GetLinearInverse()
        blockXYZInStance = np.vstack((T.TransformPoint(block.getChildFrame().transform.GetPosition()) for block in blocks))
        minBlockX = blockXYZInStance[:,0].min()

        # Bin by x (in stance frame)
        for i, block in enumerate(blocks):
            om.removeFromObjectModel(block)
            blockRows[int(round((blockXYZInStance[i,0] - minBlockX) / blockLength))].append(i)

        # Then sort by y (in stance frame)
        for row_id, row in blockRows.iteritems():
            yInLocal = [blockXYZInStance[i, 1] for i in row]
            blockRows[row_id] = [blockDescriptions[row[i]] for i in np.argsort(yInLocal)]

        for row_id in sorted(blockRows.keys()):
            for col_id, block in enumerate(blockRows[row_id]):
                block['Name'] = '%s (%d,%d)' % (self.cinderblockPrefix, row_id, col_id)
                del block['uuid']
                self.robotSystem.affordanceManager.newAffordanceFromDescription(block)


        '''
                if not blocks:
                    return

                stanceFrame = FootstepRequestGenerator.getRobotStanceFrame(self.robotSystem.robotStateModel)

                T = stanceFrame.GetLinearInverse()
                blockXYZInStance = np.vstack((T.TransformPoint(block.getChildFrame().transform.GetPosition()) for block in blocks))
                minBlockX = blockXYZInStance[:,0].min()

                rowToBlocks = defaultdict(lambda: [])


                # Bin by x (in stance frame)
                for i, block in enumerate(blocks):
                    row = int(round((blockXYZInStance[i,0] - minBlockX) / blockLength))
                    rowToBlocks[row].append(block)
                    print 'block %s row bin: %d' % (block.getProperty('Name'), row)

                # Then sort by y (in stance frame)
                for row, rowBlocks in rowToBlocks.iteritems():
                    print '---------'
                    print 'sorting row', row
                    for block in rowBlocks:
                        print '  %s' % block.getProperty('Name')

                    yInLocal = [blockXYZInStance[blocks.index(block), 1] for block in rowBlocks]
                    print yInLocal

                    rowBlocks = [rowBlocks[i] for i in np.argsort(yInLocal)]

                    print rowBlocks
                    rowToBlocks[row] = rowBlocks
                    print rowToBlocks[row]


                for row in sorted(rowToBlocks.keys()):
                    print 'renaming by row,col for row:', row
                    print rowToBlocks[row]
                    for col, block in enumerate(rowToBlocks[row]):
                        newName = '%s (%d,%d)' % (self.cinderblockPrefix, row, col)
                        print 'renaming %s to: %s' % (block.getProperty('Name'), newName)
                        block.rename(newName)
        '''

    def computeSafeRegions(self):

        om.removeFromObjectModel(om.findObjectByName('Safe terrain regions'))

        blocks = self.getCinderblockAffordances() + self.getStairAffordances()
        for block in blocks:

            d = np.array(block.getProperty('Dimensions'))/2.0
            d[0] -= blockSafetyMargin[0]
            d[1] -= blockSafetyMargin[1]

            t = block.getChildFrame().transform

            pts = [
              [d[0], d[1], d[2]],
              [d[0], -d[1], d[2]],
              [-d[0], -d[1], d[2]],
              [-d[0], d[1], d[2]]
            ]
            #print 'pts:', pts
            pts = np.array([np.array(t.TransformPoint(p)) for p in pts])
            rpySeed = transformUtils.rollPitchYawFromTransform(t)
            #print 'tx pts:', pts
            #print 'rpy seed:', rpySeed

            self.convertStepToSafeRegion(pts, rpySeed)


    def computeManualFootsteps(self):

        leadingFoot = 'right'

        blockIds = [4,0,5,1,6,2,7,3]

        blocks = self.getCinderblockAffordances()
        blocks = [blocks[i] for i in blockIds]

        f = 0.04
        w = 0.04

        offsets = [
          [0.0, w],
          [0.0, -w],
          [f, w],
          [0.0, -w],
          [-f, w],
          [f, -w],
          [0.0, w],
          [0.0, -w],
        ]

        stepFrames = []

        for block, offset in zip(blocks, offsets):
            d = np.array(block.getProperty('Dimensions'))/2.0
            t = transformUtils.copyFrame(block.getChildFrame().transform)
            pt = offset[0], offset[1], d[2]
            t.PreMultiply()
            t.Translate(pt)
            stepFrames.append(t)
            #obj = vis.showFrame(t, '%s step frame' % block.getProperty('Name'), parent='step frames', scale=0.2)

        startPose = self.getPlanningStartPose()

        helper = FootstepRequestGenerator(self.robotSystem.footstepsDriver)
        request = helper.makeFootstepRequest(startPose, stepFrames, leadingFoot)

        self.robotSystem.footstepsDriver.sendFootstepPlanRequest(request, waitForResponse=True)


    def convertStepToSafeRegion(self, step, rpySeed):
        assert step.shape[0] >= 3
        assert step.shape[1] == 3

        shapeVertices = np.array(step).transpose()[:2,:]
        s = ddapp.terrain.PolygonSegmentationNonIRIS(shapeVertices, bot_pts=ddapp.terrain.DEFAULT_FOOT_CONTACTS)

        stepCenter = np.mean(step, axis=0)
        startSeed = np.hstack([stepCenter, rpySeed])

        r = s.findSafeRegion(startSeed)

        if r is not None:
            # draw step
            d = DebugData()
            for p1, p2 in zip(step, step[1:]):
                d.addLine(p1, p2)
            d.addLine(step[-1], step[0])

            folder = om.getOrCreateContainer('Safe terrain regions')
            obj = vis.showPolyData(d.getPolyData(), 'step region %d' % len(folder.children()), parent=folder)
            obj.properties.addProperty('Enabled for Walking', True)
            obj.safe_region = r

    def getFootFrameAtSole(self, linkName):
        footSoleToOrigin = np.mean(self.robotSystem.footstepsDriver.getContactPts(), axis=0)
        startPose = self.getPlanningStartPose()
        footFrame = self.robotSystem.ikPlanner.getLinkFrameAtPose(linkName, startPose)
        footFrame.PreMultiply()
        footFrame.Translate(footSoleToOrigin)
        return footFrame


    def snapCinderblocksAtFeet(self):

        for side in ['left', 'right']:
            block = self.getCinderblockUnderFoot(side)

            print '%s block: %s' % (side, block.getProperty('Name') if block else None)
            if not block:
                continue

            blockFrame = block.getChildFrame()
            footFrame = self.getFootFrameAtSole(self.sideToFootLinkName(side))

            footRpy = transformUtils.rollPitchYawFromTransform(footFrame)
            blockRpy =  transformUtils.rollPitchYawFromTransform(blockFrame.transform)
            blockRpy[0] = footRpy[0]
            blockRpy[1] = footRpy[1]

            newBlockFrame = transformUtils.frameFromPositionAndRPY(blockFrame.transform.GetPosition(), np.degrees(blockRpy))
            blockSurfaceFrame = transformUtils.concatenateTransforms([transformUtils.frameFromPositionAndRPY([0.0, 0.0, blockHeight/2.0], [0.0, 0.0, 0.0]), newBlockFrame])

            blockSurfaceOrigin = blockSurfaceFrame.GetPosition()
            blockSurfaceNormal = transformUtils.getAxesFromTransform(blockSurfaceFrame)[2]
            footIntersection = segmentation.intersectLineWithPlane(np.array(footFrame.GetPosition()), np.array([0,0,1]), np.array(blockSurfaceOrigin), np.array(blockSurfaceNormal))
            zoffset = footIntersection[2] - footFrame.GetPosition()[2]

            newBlockFrame.PostMultiply()
            newBlockFrame.Translate(0.0, 0.0, -zoffset)

            blockFrame.copyFrame(newBlockFrame)


    def spawnCinderblocksAtFeet(self):

        for linkName in ['l_foot', 'r_foot']:
            blockFrame = self.getFootFrameAtSole(linkName)
            blockFrame.PreMultiply()
            blockFrame.Translate(0.0, 0.0, -blockHeight/2.0)

            blockId = len(self.getFitCinderblockAffordances())
            pose = transformUtils.poseFromTransform(blockFrame)
            desc = dict(classname='BoxAffordanceItem', Name='cinderblock %d' % blockId, Dimensions=[blockLength, blockWidth, blockHeight], pose=pose)
            block = self.robotSystem.affordanceManager.newAffordanceFromDescription(desc)


    def spawnTiltedCinderblocksRow(self, relativeFrame, startSequence, numberOfBlocks):

        blocks = []

        tiltAngle = 15

        baseVerticalOffset = blockHeight/2.0 + np.sin(np.radians(tiltAngle))*blockLength/2.0

        forwardOffset = blockLength
        offset = np.array([0.0, 0.0, 0.0])

        footFrames = []
        for i in xrange(numberOfBlocks):

            if i == 2:
                verticalOffset = blockHeight
            else:
                verticalOffset = 0.0

            stepSequence = (i + startSequence) % 4
            if stepSequence == 0:
                l = blockLength
                w = blockWidth
                tiltX = 0.0
                tiltY = -tiltAngle
            elif stepSequence == 1:
                l = blockWidth
                w = blockLength
                tiltX = tiltAngle
                tiltY = 0.0
            elif stepSequence == 2:
                l = blockLength
                w = blockWidth
                tiltX = 0.0
                tiltY = tiltAngle
            elif stepSequence == 3:
                l = blockWidth
                w = blockLength
                tiltX = -tiltAngle
                tiltY = 0.0

            offsetFrame = transformUtils.frameFromPositionAndRPY([forwardOffset*(i+1), 0.0, verticalOffset+baseVerticalOffset], [tiltX, tiltY, 0.0])

            offsetFrame.PostMultiply()
            offsetFrame.Concatenate(relativeFrame)

            #vis.showFrame(offsetFrame, 'cinderblock %d' % i)

            '''
            footOffsetFrame = transformUtils.frameFromPositionAndRPY([0.0, 0.0, blockHeight/2.0 + 0.07], [0.0, 0.0, 0.0])
            footOffsetFrame.PostMultiply()
            footOffsetFrame.Concatenate(offsetFrame)
            footFrames.append(offsetFrame)
            vis.showFrame(footOffsetFrame, 'footstep %d' % i)
            '''

            blockId = len(self.getCinderblockAffordances())
            pose = transformUtils.poseFromTransform(offsetFrame)
            desc = dict(classname='BoxAffordanceItem', Name='cinderblock %d' % blockId, Dimensions=[l, w, blockHeight], pose=pose)
            block = self.robotSystem.affordanceManager.newAffordanceFromDescription(desc)
            blocks.append(block)

        return blocks


    def planArmsUp(self):
        ikPlanner = self.robotSystem.ikPlanner
        startPose = self.getPlanningStartPose()
        endPose = ikPlanner.getMergedPostureFromDatabase(startPose, 'General', 'hands-forward', side='left')
        endPose = ikPlanner.getMergedPostureFromDatabase(endPose, 'General', 'hands-forward', side='right')
        ikPlanner.computeMultiPostureGoal([startPose, endPose])


class TerrainImageFitter(ImageBasedAffordanceFit):

    def __init__(self, drillDemo):
        ImageBasedAffordanceFit.__init__(self, numberOfPoints=1)
        self.drillDemo = drillDemo

    def fit(self, polyData, points):
        pass


class TerrainTaskPanel(TaskUserPanel):

    def __init__(self, robotSystem):

        TaskUserPanel.__init__(self, windowTitle='Terrain Task')

        self.robotSystem = robotSystem
        self.terrainTask = TerrainTask(robotSystem)

        self.fitter = TerrainImageFitter(self.terrainTask)
        self.initImageView(self.fitter.imageView)

        self.addDefaultProperties()
        self.addButtons()
        self.addTasks()

    def addButtons(self):
        #self.addManualButton('Spawn tilted steps', self.terrainTask.spawnTiltedCinderblocks)
        #self.addManualButton('Walk to tilted steps', self.terrainTask.walkToTiltedCinderblocks)
        self.addManualButton('Spawn blocks at feet', self.terrainTask.spawnCinderblocksAtFeet)
        self.addManualSpacer()

        self.addManualButton('Fit Blocks', self.terrainTask.requestBlockFit)
        self.addManualButton('Organize fit blocks', self.terrainTask.organizeFitBlocks)
        self.addManualButton('Raycast terrain', self.terrainTask.requestRaycastTerrain)
        self.addManualButton('Generate footsteps', self.generateFootsteps)
        self.addManualButton('Print footstep offsets', self.terrainTask.printFootstepOffsets)
        self.addManualSpacer()
        self.addManualButton('Delete front blocks', self.terrainTask.deleteFrontBlocks)
        self.addManualButton('Snap foot blocks', self.terrainTask.snapCinderblocksAtFeet)


        #self.addManualButton('Fit ground affordance', self.terrainTask.spawnGroundAffordance)

        #self.addManualSpacer()
        #self.addManualButton('Reorient blocks to robot', self.terrainTask.reorientBlocks)
        #self.addManualButton('Compute safe regions', self.terrainTask.computeSafeRegions)
        self.addManualSpacer()
        self.addManualButton('Arms up', self.terrainTask.planArmsUp)


    def addDefaultProperties(self):
        self.params.addProperty('Block Fit Algo', self.terrainTask.blockFitAlgo, attributes=om.PropertyAttributes(enumNames=['MinArea', 'ClosestSize']))
        self.params.addProperty('Constrain Block Size', self.terrainTask.constrainBlockSize)
        self.params.addProperty('Camera Texture', False, attributes=om.PropertyAttributes(hidden=False))


    def onPropertyChanged(self, propertySet, propertyName):
        if propertyName == 'Camera Texture':
            self.terrainTask.useTextures = self.params.getProperty(propertyName)
        if propertyName == 'Block Fit Algo':
            self.terrainTask.blockFitAlgo = self.params.getProperty(propertyName)
        if propertyName == 'Constrain Block Size':
            self.terrainTask.constrainBlockSize = self.params.getProperty(propertyName)

    def generateFootsteps(self):

        self.terrainTask.spawnFootstepsForCinderblocks()

    def addTasks(self):

        # some helpers
        self.folder = None
        def addTask(task, parent=None):
            parent = parent or self.folder
            self.taskTree.onAddTask(task, copy=False, parent=parent)
        def addFunc(func, name, parent=None):
            addTask(rt.CallbackTask(callback=func, name=name), parent=parent)
        def addFolder(name, parent=None):
            self.folder = self.taskTree.addGroup(name, parent=parent)
            return self.folder

