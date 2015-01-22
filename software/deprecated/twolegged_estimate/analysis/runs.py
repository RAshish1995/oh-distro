import numpy as np
import subprocess
import os
import sys
import shutil
import time
import shlex
import errno

def doAllRuns(logListFile,prefix):
    
    # create output directory
    prefix = os.path.expandvars(prefix)
    try:
        os.makedirs(prefix)
    except OSError as exc:
        if exc.errno == errno.EEXIST and os.path.isdir(prefix): pass
        else: raise

    # get all options lists
    files = open(os.path.expandvars(logListFile),'r').readlines()
    medianLengths = [5,9,15]
    runOptions = ['A','B','C']
    #windowDurations = [30, 60, 90]
    windowDurations = [30]
    weightProfiles = ['uniform','tri','ramp','revramp','revtri']

    # loop and run    
    for runOption in runOptions:
        for duration in windowDurations:
            for profile in weightProfiles:
                for medianLength in medianLengths:
                    for filename in files:
                        doRun(filename, runOption, duration, profile, medianLength, prefix)


def doRun(logFile, runOption, maxDuration, profileType, medianLength, prefix):
    #prefixName = os.path.split(prefix)[1]
    logName = os.path.split(os.path.split(logFile)[0])[1];
    runName = logName + '_' + runOption + '_' + str(maxDuration) + '_' + profileType + '_' + str(medianLength)
    sys.stdout.write('starting run %s ...\n' % (runName))
    
    # write weights file
    weightFile = os.path.expandvars('${HOME}/drc/software/config/subsystems/legged_odometry/weights.txt');
    writeWeights(maxDuration, maxDuration, profileType, weightFile)
    sys.stdout.write('  wrote weights file %s\n' % weightFile)
    
    # start up motion estimator
    motionExe = 'drc-legged-odometry'
    motionArgs = '-e -l -y' + ' -' + runOption + ' -m ' + str(medianLength)
    motionCmd = shlex.split(motionExe + ' ' + motionArgs)
    motionProc = subprocess.Popen(motionCmd, cwd='/tmp')
    sys.stdout.write('  spawned motion estimator\n')
    sys.stdout.write(motionExe + ' ' + motionArgs)
    
    # start up logplayer
    playerExe = 'lcm-logplayer'
    playerArgs = '-s 4 %s' % logFile
    playerCmd = shlex.split(playerExe + ' ' + playerArgs)
    playerProc = subprocess.Popen(playerCmd)
    sys.stdout.write('  playing log %s...' % logFile)
    playerProc.wait()
    sys.stdout.write('done\n')

    # kill everything when logplayer is done
    time.sleep(3)
    sys.stdout.write('  terminating processes...')
    motionProc.terminate()
    sys.stdout.write('done\n')
    
    # copy files
    shutil.move('/tmp/true_estimated_states.csv','%s/%s.csv' % (prefix,runName))
    sys.stdout.write('********** ALL DONE ***********\n')


def writeWeights(maxDuration, numSamples, profileType, fileName):
    
    # compute weights according to profile type
    step = maxDuration/numSamples
    times = (np.arange(numSamples)+1)*step
    weights = np.empty(np.shape(times))
    n = len(times)
    for i in range(n):
        if (profileType == 'uniform'):
            weights[i] = 1.0
        elif (profileType == 'tri'):
            if (i < n/2):
                weights[i] = i+1
            else:
                weights[i] = n-i
        elif (profileType == 'ramp'):
            weights[i] = i+1
        elif (profileType == 'revramp'):
            weights[i] = n-i
        elif (profileType == 'revtri'):
            if (i < n/2):
                weights[i] = n-i
            else:
                weights[i] = i+1
    weights /= weights.sum()

    # write to file    
    f = open(fileName,'w')
    f.write(str(1000) + '\n')
    for i in range(n):
        f.write(str(times[i]*1000) + ', ' + str(weights[i]) + '\n')