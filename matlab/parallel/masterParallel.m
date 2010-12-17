function [fOutVar,nBlockPerCPU, totCPU] = masterParallel(Parallel,fBlock,nBlock,NamFileInput,fname,fInputVar,fGlobalVar,Parallel_info,initialize)
% PARALLEL CONTEXT
% This is the most important function for the management of DYNARE parallel
% computing.
% It is the top-level function called on the master computer when parallelizing a task.

% This function have two main computational startegy for manage the matlab worker (slave process).
% 0 Simple Close/Open Stategy:
% In this case the new matlab istances (slave process) are open when
% necessary and then closed. This can happen many times during the
% simulation of a model.

% 1 Alway Open Stategy:
% In this case we have a more sophisticated management of slave processes,
% which are no longer closed at the end of each job. The slave processes
% waits for a new job (if exist). If a slave do not receives a new job after a
% fixed time it is destroyed. This solution removes the computational
% time necessary to Open/Close new matlab istances.

% The first (point 0) is the default Strategy
% i.e.(Parallel_info.leaveSlaveOpen=0). This value can be changed by the
% user in xxx.mod file or it is changed by the programmer if it necessary to
% reduce the overall computational time. See for example the
% prior_posterior_statistics.m.

% The number of parallelized threads will be equal to (nBlock-fBlock+1).
%
% INPUTS
%  o Parallel [struct vector]   copy of options_.parallel
%  o fBlock [int]               index number of the first thread
%                               (between 1 and nBlock)
%  o nBlock [int]               index number of the last thread
%  o NamFileInput [cell array]  containins the list of input files to be
%                               copied in the working directory of remote slaves
%                               2 columns, as many lines as there are files
%                               - first column contains directory paths
%                               - second column contains filenames
%  o fname [string]             name of the function to be parallelized, and
%                               which will be run on the slaves
%  o fInputVar [struct]         structure containing local variables to be used
%                               by fName on the slaves
%  o fGlobalVar [struct]        structure containing global variables to be used
%                               by fName on the slaves
%  o Parallel_info              []
%  o initialize                 []
%
% OUTPUT
%  o fOutVar [struct vector]   result of the parallel computation, one
%                              struct per thread
%  o nBlockPerCPU [int vector] for each CPU used, indicates the number of
%                              threads run on that CPU
%  o totCPU [int]              total number of CPU used (can be lower than
%                              the number of CPU declared in "Parallel", if
%                              the number of required threads is lower)

% Copyright (C) 2009-2010 Dynare Team
%
% This file is part of Dynare.
%
% Dynare is free software: you can redistribute it and/or modify
% it under the terms of the GNU General Public License as published by
% the Free Software Foundation, either version 3 of the License, or
% (at your option) any later version.
%
% Dynare is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU General Public License for more details.
%
% You should have received a copy of the GNU General Public License
% along with Dynare.  If not, see <http://www.gnu.org/licenses/>.



% If islocal==0, create a new directory for remote computation.
% This directory is named using current data and time,
% is used only one time and then deleted.

persistent PRCDir
% PRCDir = Present Remote Computational Directory!

Strategy=Parallel_info.leaveSlaveOpen;

islocal = 1;
for j=1:length(Parallel),
    islocal=islocal*Parallel(j).Local;
end
if nargin>8 && initialize==1
    if islocal == 0,
        PRCDir=CreateTimeString();
        assignin('base','PRCDirTmp',PRCDir),
        evalin('base','options_.parallel_info.RemoteTmpFolder=PRCDirTmp;')
        evalin('base','clear PRCDirTmp,')
    else
        % Delete the traces (if existing) of last local session of computations.
        if Strategy==1,
            mydelete(['slaveParallel_input*.mat']);
        end
    end
    return
end



% Only for testing!

% if Strategy==0
%     disp('User Strategy Now Is Open/Close (0)');
% else
%     disp('User Strategy Now Is Always Open (1)');
% end

if Strategy==1
    totCPU=0;
end


% Determine my hostname and my working directory.

DyMo=pwd;
% fInputVar.DyMo=DyMo;
if ~(isunix || (~matlab_ver_less_than('7.4') && ismac)) ,
    [tempo, MasterName]=system('hostname');
    MasterName=deblank(MasterName);
end
% fInputVar.MasterName = MasterName;


% Save input data for use by the slaves.
switch Strategy
    case 0
        if exist('fGlobalVar'),
            save([fname,'_input.mat'],'fInputVar','fGlobalVar')
        else
            save([fname,'_input.mat'],'fInputVar')
        end
        save([fname,'_input.mat'],'Parallel','-append')
        
    case 1
        if exist('fGlobalVar'),
            save(['temp_input.mat'],'fInputVar','fGlobalVar')
        else
            save(['temp_input.mat'],'fInputVar')
        end
        save(['temp_input.mat'],'Parallel','-append')
end


% Determine the total number of available CPUs, and the number of threads
% to run on each CPU.

[nCPU, totCPU, nBlockPerCPU, totSlaves] = distributeJobs(Parallel, fBlock, nBlock);
offset0 = fBlock-1;


% Clean up remnants of previous runs.
mydelete(['comp_status_',fname,'*.mat']);
mydelete(['P_',fname,'*End.txt']);


% Create a shell script containing the commands to launch the required
% tasks on the slaves.
fid = fopen('ConcurrentCommand1.bat','w+');


% Create the directory devoted to remote computation.
if isempty(PRCDir) && ~islocal,
    error('PRCDir not initialized!')
else
    dynareParallelMkDir(PRCDir,Parallel(1:totSlaves));
end


for j=1:totCPU,
    
    
    if Strategy==1
        command1 = ' ';
    end
    
    indPC=min(find(nCPU>=j));
    
    % According to the information contained in configuration file, compThread can limit MATLAB
    % to a single computational thread. By default, MATLAB makes use of the multithreading
    % capabilities of the computer on which it is running. Nevertheless
    % exsperimental results show as matlab native
    % multithreading limit the performaces when the parallel computing is active.
    
    
    if strcmp('true',Parallel(indPC).SingleCompThread),
        compThread = '-singleCompThread';
    else
        compThread = '';
    end
    
    if indPC>1
        nCPU0 = nCPU(indPC-1);
    else
        nCPU0=0;
    end
    offset = sum(nBlockPerCPU(1:j-1))+offset0;
    
    % Create a file used to monitoring if a parallel block (core)
    % computation is finished or not.
    
    fid1=fopen(['P_',fname,'_',int2str(j),'End.txt'],'w+');
    fclose(fid1);
    
    if Strategy==1,
        
        fblck = offset+1;
        nblck = sum(nBlockPerCPU(1:j));
        save temp_input fblck nblck fname -append;
        copyfile('temp_input.mat',['slaveJob',int2str(j),'.mat'])
        if Parallel(indPC).Local ==0,
            fid1=fopen(['stayalive',int2str(j),'.txt'],'w+');
            fclose(fid1);
            dynareParallelSendFiles(['stayalive',int2str(j),'.txt'],PRCDir,Parallel(indPC));
            mydelete(['stayalive',int2str(j),'.txt']);
        end
        % Wait for possibly local alive CPU to start the new job or close by
        % internal criteria.
        pause(1);
        newInstance = 0;
        
        % Check if j CPU is already alive.
        if isempty(dynareParallelDir(['P_slave_',int2str(j),'End.txt'],PRCDir,Parallel(indPC)));
            fid1=fopen(['P_slave_',int2str(j),'End.txt'],'w+');
            fclose(fid1);
            if Parallel(indPC).Local==0,
                dynareParallelSendFiles(['P_slave_',int2str(j),'End.txt'],PRCDir,Parallel(indPC));
                delete(['P_slave_',int2str(j),'End.txt']);
            end
            
            newInstance = 1;
            storeGlobalVars( ['slaveParallel_input',int2str(j)]);
            save( ['slaveParallel_input',int2str(j)],'Parallel','-append');
            % Prepare global vars for Slave.
        end
    else
        
        % If the computation is executed remotely all the necessary files
        % are created localy, then copied in remote directory and then
        % deleted (loacal)!
        
        save( ['slaveParallel_input',int2str(j)],'Parallel');
        
        if Parallel(indPC).Local==0,
            dynareParallelSendFiles(['P_',fname,'_',int2str(j),'End.txt'],PRCDir,Parallel(indPC));
            delete(['P_',fname,'_',int2str(j),'End.txt']);
            
            dynareParallelSendFiles(['slaveParallel_input',int2str(j),'.mat'],PRCDir,Parallel(indPC));
            delete(['slaveParallel_input',int2str(j),'.mat']);
            
        end
        
    end
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % The following 'switch - case' code is the core of this function!
    switch Strategy
        case 0
            
            if Parallel(indPC).Local == 1,                                  % 0.1 Run on the local machine (localhost).
                
                if isunix || (~matlab_ver_less_than('7.4') && ismac),
                    if exist('OCTAVE_VERSION')
                        command1=['octave --eval "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''')" &'];
                    else
                        command1=[Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''')" &'];
                    end
                else
                    if exist('OCTAVE_VERSION')
                        command1=['start /B psexec -W ',DyMo, ' -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)),' -low  octave --eval "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''')"'];
                    else
                        command1=['start /B psexec -W ',DyMo, ' -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)),' -low  ',Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''')"'];
                    end
                end
            else                                                            % 0.2 Parallel(indPC).Local==0: Run using network on remote machine or also on local machine.
                if j==nCPU0+1,
                    dynareParallelSendFiles([fname,'_input.mat'],PRCDir,Parallel(indPC));
                    dynareParallelSendFiles(NamFileInput,PRCDir,Parallel(indPC));
                end
                
                if isunix || (~matlab_ver_less_than('7.4') && ismac),
                    if exist('OCTAVE_VERSION'),
                        command1=['ssh ',Parallel(indPC).UserName,'@',Parallel(indPC).ComputerName,' "cd ',Parallel(indPC).RemoteDirectory,'/',PRCDir, '; octave --eval \"addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''');\" " &'];
                    else
                        command1=['ssh ',Parallel(indPC).UserName,'@',Parallel(indPC).ComputerName,' "cd ',Parallel(indPC).RemoteDirectory,'/',PRCDir, '; ',Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r \"addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''');\" " &'];
                    end
                else
                    if ~strcmp(Parallel(indPC).ComputerName,MasterName),  % 0.3 Run on a remote machine!
                        if exist('OCTAVE_VERSION'),
                            command1=['start /B psexec \\',Parallel(indPC).ComputerName,' -e -u ',Parallel(indPC).UserName,' -p ',Parallel(indPC).Password,' -W ',Parallel(indPC).RemoteDrive,':\',Parallel(indPC).RemoteDirectory,'\',PRCDir,'\ -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)), ...
                                ' -low  octave --eval "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''')"'];
                        else
                            command1=['start /B psexec \\',Parallel(indPC).ComputerName,' -e -u ',Parallel(indPC).UserName,' -p ',Parallel(indPC).Password,' -W ',Parallel(indPC).RemoteDrive,':\',Parallel(indPC).RemoteDirectory,'\',PRCDir,'\ -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)), ...
                                ' -low  ',Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''')"'];
                        end
                    else                                                  % 0.4 Run on the local machine via the network
                        if exist('OCTAVE_VERSION'),
                            command1=['start /B psexec \\',Parallel(indPC).ComputerName,' -e -W ',Parallel(indPC).RemoteDrive,':\',Parallel(indPC).RemoteDirectory,'\',PRCDir,'\ -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)), ...
                                ' -low  octave --eval "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''')"'];
                        else
                            command1=['start /B psexec \\',Parallel(indPC).ComputerName,' -e -W ',Parallel(indPC).RemoteDrive,':\',Parallel(indPC).RemoteDirectory,'\',PRCDir,'\ -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)), ...
                                ' -low  ',Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); fParallel(',int2str(offset+1),',',int2str(sum(nBlockPerCPU(1:j))),',',int2str(j),',',int2str(indPC),',''',fname,''')"'];
                        end
                    end
                end
            end
            
            
        case 1
            if Parallel(indPC).Local == 1 & newInstance,                   % 1.1 Run on the local machine.
                if isunix || (~matlab_ver_less_than('7.4') && ismac),
                    if exist('OCTAVE_VERSION')
                        command1=['octave --eval "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),')" &'];
                    else
                        command1=[Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),')" &'];
                    end
                else
                    if exist('OCTAVE_VERSION')
                        command1=['start /B psexec -W ',DyMo, ' -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)),' -low  octave --eval "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),')"'];
                    else
                        command1=['start /B psexec -W ',DyMo, ' -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)),' -low  ',Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),')"'];
                    end
                end
            elseif Parallel(indPC).Local==0,                                % 1.2 Run using network on remote machine or also on local machine.
                if j==nCPU0+1,
                    dynareParallelSendFiles(NamFileInput,PRCDir,Parallel(indPC));
                end
                dynareParallelSendFiles(['P_',fname,'_',int2str(j),'End.txt'],PRCDir,Parallel(indPC));
                delete(['P_',fname,'_',int2str(j),'End.txt']);
                dynareParallelSendFiles(['slaveJob',int2str(j),'.mat'],PRCDir,Parallel(indPC));
                delete(['slaveJob',int2str(j),'.mat']);
                if newInstance,
                    dynareParallelSendFiles(['slaveParallel_input',int2str(j),'.mat'],PRCDir,Parallel(indPC))
                    if isunix || (~matlab_ver_less_than('7.4') && ismac),
                        if exist('OCTAVE_VERSION'),
                            command1=['ssh ',Parallel(indPC).UserName,'@',Parallel(indPC).ComputerName,' "cd ',Parallel(indPC).RemoteDirectory,'/',PRCDir '; octave --eval \"addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),');\" " &'];
                        else
                            command1=['ssh ',Parallel(indPC).UserName,'@',Parallel(indPC).ComputerName,' "cd ',Parallel(indPC).RemoteDirectory,'/',PRCDir '; ',Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r \"addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),');\" " &'];
                        end
                    else
                        if ~strcmp(Parallel(indPC).ComputerName,MasterName), % 1.3 Run on a remote machine.
                            if exist('OCTAVE_VERSION'),
                                command1=['start /B psexec \\',Parallel(indPC).ComputerName,' -e -u ',Parallel(indPC).UserName,' -p ',Parallel(indPC).Password,' -W ',Parallel(indPC).RemoteDrive,':\',Parallel(indPC).RemoteDirectory,'\',PRCDir,'\ -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)), ...
                                    ' -low  octave --eval "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),')"'];
                            else
                                command1=['start /B psexec \\',Parallel(indPC).ComputerName,' -e -u ',Parallel(indPC).UserName,' -p ',Parallel(indPC).Password,' -W ',Parallel(indPC).RemoteDrive,':\',Parallel(indPC).RemoteDirectory,'\',PRCDir,'\ -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)), ...
                                    ' -low  ',Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),')"'];
                            end
                        else                                                % 1.4 Run on the local machine via the network.
                            if exist('OCTAVE_VERSION'),
                                command1=['start /B psexec \\',Parallel(indPC).ComputerName,' -e -W ',Parallel(indPC).RemoteDrive,':\',Parallel(indPC).RemoteDirectory,'\',PRCDir,'\ -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)), ...
                                    ' -low  octave --eval "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),')"'];
                            else
                                command1=['start /B psexec \\',Parallel(indPC).ComputerName,' -e -W ',Parallel(indPC).RemoteDrive,':\',Parallel(indPC).RemoteDirectory,'\',PRCDir,'\ -a ',int2str(Parallel(indPC).CPUnbr(j-nCPU0)), ...
                                    ' -low  ',Parallel(indPC).MatlabOctavePath,' -nosplash -nodesktop -minimize ',compThread,' -r "addpath(''',Parallel(indPC).DynarePath,'''), dynareroot = dynare_config(); slaveParallel(',int2str(j),',',int2str(indPC),')"'];
                            end
                        end
                    end
                end
            end
            
    end
    
    fprintf(fid,'%s\n',command1);
    
end

% In This way we are sure that the file 'ConcurrentCommand1.bat' is
% closed and then it can be deleted!
while (1)
    StatusOfCC1_bat = fclose(fid);
    if StatusOfCC1_bat==0
        break
    end
end

% Run the slaves.
if isunix || (~matlab_ver_less_than('7.4') && ismac),
    system('sh ConcurrentCommand1.bat &');
    pause(1)
else
    system('ConcurrentCommand1.bat');
end


% For matlab enviroment with options_.console_mode = 0:
% create a parallel (local/remote) specialized computational status bars!

global options_



% Create a parallel (local/remote) specialized computational status bars!

if exist('OCTAVE_VERSION') || (options_.console_mode == 1),
    diary off;
    if exist('OCTAVE_VERSION')
        printf('\n');
    else
        fprintf('\n');
    end
else
    hfigstatus = figure('name',['Parallel ',fname],...
        'DockControls','off', ...
        'IntegerHandle','off', ...
        'Interruptible','off', ...
        'MenuBar', 'none', ...
        'NumberTitle','off', ...
        'Renderer','Painters', ...
        'Resize','off');
    
    vspace = 0.1;
    ncol = ceil(totCPU/10);
    hspace = 0.9/ncol;
    hstatus(1) = axes('position',[0.05/ncol 0.92 0.9/ncol 0.03], ...
        'box','on','xtick',[],'ytick',[],'xlim',[0 1],'ylim',[0 1]);
    set(hstatus(1),'Units','pixels')
    hpixel = get(hstatus(1),'Position');
    hfigure = get(hfigstatus,'Position');
    hfigure(4)=hpixel(4)*10/3*min(10,totCPU);
    set(hfigstatus,'Position',hfigure)
    set(hstatus(1),'Units','normalized'),
    vspace = max(0.1,1/totCPU);
    vstart = 1-vspace+0.2*vspace;
    for j=1:totCPU,
        jrow = mod(j-1,10)+1;
        jcol = ceil(j/10);
        hstatus(j) = axes('position',[0.05/ncol+(jcol-1)/ncol vstart-vspace*(jrow-1) 0.9/ncol 0.3*vspace], ...
            'box','on','xtick',[],'ytick',[],'xlim',[0 1],'ylim',[0 1]);
        hpat(j) = patch([0 0 0 0],[0 1 1 0],'r','EdgeColor','r');
        htit(j) = title(['Initialize ...']);
        
    end
    
    cumBlockPerCPU = cumsum(nBlockPerCPU);
end
pcerdone = NaN(1,totCPU);
idCPU = NaN(1,totCPU);

delete(['comp_status_',fname,'*.mat']);


% Wait for the slaves to finish their job, and display some progress
% information meanwhile.

% Caption for console mode computing ...

if (options_.console_mode == 1)
    fnameTemp=fname;
    
    L=length(fnameTemp);
    
    PoCo=strfind(fnameTemp,'_core');
    
    for i=PoCo:L
        if i==PoCo
            fnameTemp(i)=' ';
        else
            fnameTemp(i)='.';
        end
    end
     
    for i=1:L
        if  fnameTemp(i)=='_';
            fnameTemp(i)=' ';
        end
    end
    
     fnameTemp(L)='';
    
    Information=['Parallel ' fnameTemp ' Computing ...'];
    fprintf([Information,'\n\n']);
    
end


ForEver=1;
statusString = '';

while (ForEver)
    
    waitbarString = '';
    statusString0 = repmat('\b',1,length(sprintf(statusString, 100 .* pcerdone)));
    statusString = '';
    
    pause(1)
    
    try
        if islocal ==0,
            dynareParallelGetFiles(['comp_status_',fname,'*.mat'],PRCDir,Parallel(1:totSlaves));
        end
    catch
    end
    
    for j=1:totCPU,
        try
            if ~isempty(['comp_status_',fname,int2str(j),'.mat'])
                load(['comp_status_',fname,int2str(j),'.mat']);
            end
            pcerdone(j) = prtfrc;
            idCPU(j) = njob;
            if exist('OCTAVE_VERSION') || (options_.console_mode == 1),
                statusString = [statusString, int2str(j), ' %3.f%% done! '];
            else
                status_String{j} = waitbarString;
                status_Title{j} = waitbarTitle;
            end
        catch % ME
            % To define!
            if exist('OCTAVE_VERSION') || (options_.console_mode == 1),
                statusString = [statusString, int2str(j), ' %3.f%% done! '];
            end
        end
    end
    if exist('OCTAVE_VERSION') || (options_.console_mode == 1),
        if exist('OCTAVE_VERSION')
            printf([statusString,'\r'], 100 .* pcerdone);
        else
            if ~isempty(statusString)
                fprintf([statusString0,statusString], 100 .* pcerdone); 
            end
        end
        
    else
        for j=1:totCPU,
            try
                set(hpat(j),'XData',[0 0 pcerdone(j) pcerdone(j)]);
                set(htit(j),'String',[status_Title{j},' - ',status_String{j}]);
            catch ME
                
            end
        end
    end
    
    if isempty(dynareParallelDir(['P_',fname,'_*End.txt'],PRCDir,Parallel(1:totSlaves)));
        HoTuttiGliOutput=0;
        for j=1:totCPU,
            if ~isempty(dynareParallelDir([fname,'_output_',int2str(j),'.mat'],PRCDir,Parallel(1:totSlaves)))
                HoTuttiGliOutput=HoTuttiGliOutput+1;
            end
        end
        
        if HoTuttiGliOutput==totCPU,
            mydelete(['comp_status_',fname,'*.mat']);
            if exist('OCTAVE_VERSION')|| (options_.console_mode == 1),
                if exist('OCTAVE_VERSION')
                    printf('\n');
                else
                    fprintf('\n');
                    fprintf(['End Parallel Session ....','\n\n']);
                end
                diary on;
            else
                close(hfigstatus),
            end
            
            break
        else
            disp('Waiting for output files from slaves ...')
        end
    end
    
end

% Create return value.
iscrash = 0;
for j=1:totCPU,
    indPC=min(find(nCPU>=j));
    dynareParallelGetFiles([fname,'_output_',int2str(j),'.mat'],PRCDir,Parallel(indPC));
    load([fname,'_output_',int2str(j),'.mat'],'fOutputVar');
    delete([fname,'_output_',int2str(j),'.mat']);
    if isfield(fOutputVar,'OutputFileName'),
        dynareParallelGetFiles([fOutputVar.OutputFileName],PRCDir,Parallel(indPC));
    end
    if isfield(fOutputVar,'error'),
        disp(['Job number ',int2str(j),' crashed with error:']);
        iscrash=1;
        disp([fOutputVar.error.message]);
        for jstack=1:length(fOutputVar.error.stack)
            fOutputVar.error.stack(jstack),
        end
    else
        fOutVar(j)=fOutputVar;
    end
end
if iscrash,
    error('Remote jobs crashed');
end

pause(1), % Wait for all remote diary off completed

% Cleanup.
dynareParallelGetFiles('*.log',PRCDir,Parallel(1:totSlaves));

switch Strategy
    case 0
        for indPC=1:length(Parallel)
            if Parallel(indPC).Local == 0
                dynareParallelRmDir(PRCDir,Parallel(indPC));
            end
            
            if isempty(dir('dynareParallelLogFiles'))
                [A B C]=rmdir('dynareParallelLogFiles');
                mkdir('dynareParallelLogFiles');
            end
            
            copyfile('*.log','dynareParallelLogFiles');
            delete([fname,'*.log']);
            
            mydelete(['*_core*_input*.mat']);
            %             if Parallel(indPC).Local == 1
            %                 delete(['slaveParallel_input*.mat']);
            %             end
            
        end
        
        delete ConcurrentCommand1.bat
    case 1
        delete(['temp_input.mat'])
        if newInstance,
            if isempty(dir('dynareParallelLogFiles'))
                [A B C]=rmdir('dynareParallelLogFiles');
                mkdir('dynareParallelLogFiles');
            end
        end
        copyfile('*.log','dynareParallelLogFiles');
        if newInstance,
            delete ConcurrentCommand1.bat
        end
end




