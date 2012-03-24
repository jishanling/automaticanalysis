%% Automatic analysis - do processing with parallel engine
% Main engine which runs different stages
% Pass parameter file set up in aa_user.m with help of recipes.
% Rhodri Cusack MRC CBU Cambridge 2004-2008
% Second parameter in parallel version specifies to allow exisiting worker
% pool to continue
% function [aap]=aa_doprocessing(aap,bucket,bucketfordicom,workerid,analysisid,receipthandle)
%
% Major revision July 2008:
%  Divided phase of launching workers (and allocating jobs to them) for the
%  phase
%  of passing the details to them once they're ready to work. This means
%  many workers can prepare for work simultaneously, and then be handed
%  their allocated jobs together. It makes everything more snappy.
% [RC]
%
% Added 'internal' domain, for allowing modules to parallelise over their
% own vaiables (djm)
%

% March 2009-April 2010
%  Support for AWS being included
% [RC]

% 2010-03-17: There has been a major change in the dependency description.
% Previously, the 'tobecompletedfirst' field alone determined what stages
% were required before others. Now, however, the 'tobecompletedfirst'
% describes a chain describing the basic pipeline. For each stage, this
% chain is then analyzed to find the stages that provide the outputs that
% this stage needs as input. Then, only these stages are actually defined
% as dependencies. Other stages that don't provide outputs that are used by
% the current stage, but are earlier in the 'tobecompletedfirst' pipeline,
% are not marked as dependencies.
% [RC]

function [aap]=aa_doprocessing(aap,username,bucket,bucketfordicom,workerid,analysisid,jobid)

if (exist('bucket','var'))
    % Get username
    [s w]=aas_shell('whoami');
    username=strtok(w);
end;
% Defend against command insertion
aap=aas_validatepaths(aap);

% launch SPM if not already running
aap=aas_checkspmrunning(aap);

% Check this is compiled
try
    utc_time();
catch
    fprintf('You must compile the utc_time library\n')
end;

if (isstr(aap))
    tmp=load(aap);
    aap=tmp.aap;
end;

if (~exist('dontcloseexistingworkers','var'))
    dontcloseexistingworkers=[];
end;

% Over-ride analysisid if provided in command line
if (exist('analysisid','var'))
    aap.directory_conventions.analysisid=analysisid;
end;

global defaults;
global aaparallel
global aaworker

if (exist('username','var'))
    aaworker.username=username;
    aap=aws_setupqnames(aap,username);
    if (exist('secretkey','var'))
        aaworker.aacc=aacc(username,secretkey);
    end;
end

try
    aaworker.parmpath;
catch
    aaworker.parmpath=aaworker_getparmpath(aap,0);
end;

if (strcmp(aap.directory_conventions.remotefilesystem,'s3'))
    aaworker.bucket=bucket;
    aaworker.bucketfordicom=bucketfordicom;
end;


aap.internal.pwd=pwd;

if (isempty(aaparallel))
    while(1)
        aaparallel.workerlist=[];
        
        aaparallel.numberofworkers=8;
        
        % aaparallel.retrydelays=[10 60 300 3600 5*3600]; % seconds delay before successive retries
        aaparallel.retrydelays=[2:9 60 300 3600]; % djm: temporary solution to get past memory errors
        
        if (exist('workerid','var'))
            aaparallel.processkey=workerid;
        else
            aaparallel.processkey=num2str(round(rand(1)*1e6));
        end;
        aaparallel.nextworkernumber=num2str(aaparallel.processkey*1000);
        
        
        pth=aaworker_getparmpath(aap,0,true);
        [subpth nme ext]=fileparts(pth);
        
        fn=dir(fullfile(subpth,[sprintf('aaworker,%d',aaparallel.processkey) '*']));
        if (isempty(fn)) % No directories starting with this process key
            break;
        end;
        
    end;
else
    % Clear out all of the old workers: this is non-unionised enterprise
    %     if (isempty(dontcloseexistingworkers))
    %         aa_closeallworkers;
    %     end;
end;

if (exist('jobid','var'))
    aaworker.jobid=jobid;
else
    aaworker.jobid=aaparallel.processkey;
end;

aas_log(aap,0,['AUTOMATIC ANALYSIS ' datestr(now)]);
aas_log(aap,0,'=============================================================');
aas_log(aap,0,sprintf('Parallel process ID %s',aaparallel.processkey));

% Copy SPM defaults from aap structure
defaults=aap.spm.defaults;

% Check AA version
aas_requiresversion(aap);

% Run initialisation modules
aap=aas_doprocessing_initialisationmodules(aap);

% Save AAP structure
%  could save aaps somewhere on S3 too?
studypath=aas_getstudypath(aap);
if (strcmp(aap.directory_conventions.remotefilesystem,'none'))
    aapsavefn=fullfile(studypath,'aap_parameters');
    if (isempty(dir(studypath)))
        [s w]=aas_shell(['mkdir ' studypath]);
        if (s)
            aas_log(aap,1,sprintf('Problem making directory%s',studypath));
        end;
    end;
    aap.internal.aapversion=which('aa_doprocessing');
    save(aapsavefn,'aap');
end;

% THE MODULES IN AAP.TASKLIST.STAGES ARE RUN IF A CORRESPONDING DONE_ FLAG
% IS NOT FOUND. ONE IS CREATED AFTER SUCCESSFUL EXECUTION
% Now run stage-by-stage tasks

% get dependencies of stages, referenced in both directions (aap.internal.dependenton
% and aap.internal.dependencyof)

aap=builddependencymap(aap);

% Use input and output stream information in XML header to find
% out what data comes from where and goes where
aap=findinputstreamsources(aap);

% Store these initial settings before any module specific customisation
aap.internal.aap_initial=aap;
aap.internal.aap_initial.aap.internal.aap_initial=[]; % Prevent recursively expanding storage

% Choose where to run all tasks
switch (aap.options.wheretoprocess)
    case 'localsingle'
        taskqueue=aaq_localsingle(aap);
    case 'localparallel'
        taskqueue=aaq_localparallel(aap);
    case 'condor'
        taskqueue=aaq_condor(aap);
    case 'aws'
        taskqueue=aaq_aws(aap);
        %        taskqueue.clearawsqueue(); no longer cleared!
    otherwise
        aas_log(aap,true,sprintf('Unknown aap.options.wheretoprocess, %s\n',aap.options.wheretoprocess));
end;

% Check registered with drupal
if (strcmp(aap.directory_conventions.remotefilesystem,'s3'))
    % Get bucket nid
    [aap waserror aaworker.bucket_drupalnid]=drupal_checkexists(aap,'bucket',aaworker.bucket);
    
    % Check all subjects are specified as datasets that belong to the job...
%     attr=[];
%     for i=1:length(aap.acq_details.subjects)
%         attr.datasetref(i).nid=aap.acq_details.subjects(i).drupalnid;
%     end;
%     
%     % Register analysis (or "job") with Drupal
%     [aap waserror aap.directory_conventions.analysisid_drupalnid]=drupal_checkexists(aap,'job',aap.directory_conventions.analysisid,attr,aaworker.bucket_drupalnid,aaworker.bucket);
end;

mytasks={'checkrequirements','doit'}; %
for l=1:length(mytasks)
    for k=1:length(aap.tasklist.main.module)
        task=mytasks{l};
        % allow full path of module to be provided [djm]
        [stagepath stagename]=fileparts(aap.tasklist.main.module(k).name);
        index=aap.tasklist.main.module(k).index;
        
        if (isfield(aap.schema.tasksettings.(stagename)(index).ATTRIBUTE,'mfile_alias'))
            mfile_alias=aap.schema.tasksettings.(stagename)(index).ATTRIBUTE.mfile_alias;
        else
            mfile_alias=stagename;
        end;
        
        aap=aas_setcurrenttask(aap,k);
        
        % retrieve description from module
        description=aap.schema.tasksettings.(stagename)(index).ATTRIBUTE.desc;
        
        % find out whether this module needs to be executed once per study, subject or session
        domain=aap.schema.tasksettings.(stagename)(index).ATTRIBUTE.domain;
        
        %  If multiple repetitions of a module, add 02,03 etc to end of doneflag
        doneflagname=aas_doneflag_getname(aap,k);
        % Start setting up the descriptor for the parallel queue
        clear taskmask
        taskmask.domain=domain;
        taskmask.k=k;
        taskmask.task=task;
        taskmask.stagename=stagename;
        taskmask.studypath=aas_getstudypath(aap,aap.directory_conventions.remotefilesystem);
        
        completefirst=aap.internal.inputstreamsources{k}.stream;
        
        % What needs to finish depends upon the domain of this stage and
        % the previous one. So, if both are session level, then the single
        % session needs to finish the previous stage before the next stage
        % starts on this session. If the latter is subject level, all of
        % the sessions must finish.
        % Now execute the module, and change the 'done' flags if task='doit'
        switch (domain)
            case 'study'
                doneflag=aas_doneflag_getpath(aap,k);
                if (aas_doneflagexists(aap,doneflag))
                    if (strcmp(task,'doit'))
                        aas_log(aap,0,sprintf('- done: %s',description));
                    end;
                else
                    switch (task)
                        case 'checkrequirements'
                            [aap,resp]=aa_feval(mfile_alias,aap,task);
                            if (length(resp)>0)
                                aas_log(aap,0,['\n***WARNING: ' resp]);
                            end;
                        case 'doit'
                            tic
                            % before starting current stage, delete done_
                            % flag for stages that are dependencies of it
                            for k0i=1:length(aap.internal.outputstreamdestinations{k}.stream)
                                aas_delete_doneflag(aap,aap.internal.outputstreamdestinations{k}.stream(k0i).destnumber);
                            end;
                            
                            % work out what needs to be done before we can
                            % execute this stage
                            completefirst=aap.internal.inputstreamsources{k}.stream;
                            tbcf=[];
                            
                            % allow multiple dependecies
                            for k0i=1:length(completefirst)
                                
                                switch(completefirst(k0i).sourcedomain)
                                    case 'study'
                                        tbcf={aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber)};
                                    case 'subject'
                                        for i=1:length(aap.acq_details.subjects)
                                            tbcf=[tbcf {aas_doneflag_getpath(aap,i,completefirst(k0i).sourcenumber)}];
                                        end;
                                    case 'session'
                                        for i=1:length(aap.acq_details.subjects)
                                            for j=aap.acq_details.selected_sessions
                                                tbcf=[tbcf {aas_doneflag_getpath(aap,i,j,completefirst(k0i).sourcenumber)}];
                                            end;
                                        end;
                                    case 'internal'
                                        % Get parallel parts of stage on
                                        % which this one is dependent
                                        loopvar=getparallelparts(aap,k0i);
                                        
                                        for x=1:length(loopvar)
                                            if ischar(loopvar{x})
                                                previousdoneflag=fullfile(aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber),[loopvar{x} '.done']); % file in directory
                                            elseif isstruct(loopvar{x})
                                                try c={loopvar{x}.id};
                                                catch c=strcat(struct2cell(loopvar{x}),'.'); % Convert structure to cell
                                                end
                                                previousdoneflag=fullfile(aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber),[c{:} 'done']); % file in directory
                                            end
                                            tbcf=[tbcf {previousdoneflag}];
                                        end
                                end;
                            end;
                            taskmask.tobecompletedfirst=tbcf;
                            taskmask.i=0;
                            taskmask.j=0;
                            
                            % now queue current stage
                            aas_log(aap,0,sprintf('MODULE %s PENDING: %s',aap.tasklist.main.module(k).name,description));
                            taskmask.doneflag=doneflag;
                            taskmask.description=description;
                            taskqueue.addtask(taskmask);
                    end;
                    
                end;
            case 'subject'
                msg='';
                alldone=true;
                for i=1:length(aap.acq_details.subjects)
                    doneflag=aas_doneflag_getpath(aap,i,k);
                    if (aas_doneflagexists(aap,doneflag))
                        if (strcmp(task,'doit'))
                            msg=[msg sprintf('- done: %s for %s \n',description,aas_getsubjname(aap,i))];
                        end;
                    else
                        alldone=false;
                        switch (task)
                            case 'checkrequirements'
                                [aap,resp]=aa_feval(mfile_alias,aap,task,i);
                                if (length(resp)>0)
                                    aas_log(aap,0,['\n***WARNING: ' resp]);
                                end;
                            case 'doit'
                                tic
                                % before starting current stage, delete done_
                                % flag for next one
                                for k0i=1:length(aap.internal.outputstreamdestinations{k}.stream)
                                    aas_delete_doneflag(aap,aap.internal.outputstreamdestinations{k}.stream(k0i).destnumber,i);
                                end;
                                
                                % work out what needs to be done before we can
                                % execute this stage
                                completefirst=aap.internal.inputstreamsources{k}.stream;
                                tbcf=[];
                                for k0i=1:length(completefirst)
                                    switch(completefirst(k0i).sourcedomain)
                                        case 'study'
                                            tbcf={aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber)};
                                        case 'subject'
                                            tbcf=[tbcf {aas_doneflag_getpath(aap,i,completefirst(k0i).sourcenumber)}];
                                        case 'session'
                                            for j=aap.acq_details.selected_sessions
                                                tbcf=[tbcf {aas_doneflag_getpath(aap,i,j,completefirst(k0i).sourcenumber)}];
                                            end;
                                        case 'internal'
                                            % Get parallel parts of stage on
                                            % which this one is dependent
                                            loopvar=getparallelparts(aap,k0i);
                                            for x=1:length(loopvar)
                                                if ischar(loopvar{x})
                                                    previousdoneflag=fullfile(aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber),[loopvar{x} '.done']); % file in directory
                                                elseif isstruct(loopvar{x})
                                                    try c={loopvar{x}.id};
                                                    catch c=strcat(struct2cell(loopvar{x}),'.'); % Convert structure to cell
                                                    end
                                                    previousdoneflag=fullfile(aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber),[c{:} 'done']); % file in directory
                                                end
                                                tbcf=[tbcf {previousdoneflag}];
                                            end
                                    end;
                                end;
                                taskmask.tobecompletedfirst=tbcf;
                                
                                % now queue current stage
                                aas_log(aap,0,sprintf('MODULE %s PENDING: %s for %s',stagename,description,aas_getsubjname(aap,i)));
                                taskmask.i=i;
                                taskmask.j=0;
                                taskmask.doneflag=doneflag;
                                taskmask.description=sprintf('%s for %s',description,aas_getsubjname(aap,i));
                                taskqueue.addtask(taskmask);
                        end;
                    end;
                end;
                if (strcmp(task,'doit'))
                    if (alldone)
                        aas_log(aap,false,sprintf('- done: %s for all subjects',description));
                    else
                        if (length(msg)>2)
                            msg=msg(1:length(msg-2));
                        end;
                        
                        aas_log(aap,false,msg);
                    end;
                end;
            case 'session'
                alldone=true;
                msg='';
                for i=1:length(aap.acq_details.subjects)
                    for j=aap.acq_details.selected_sessions
                        doneflag=aas_doneflag_getpath(aap,i,j,k);
                        if (aas_doneflagexists(aap,doneflag))
                            if (strcmp(task,'doit'))
                                msg=[msg sprintf('- done: %s for %s\n',description,aas_getsessname(aap,i,j))];
                                alldone=true;
                            end;
                        else
                            alldone=false;
                            switch (task)
                                case 'checkrequirements'
                                    [aap,resp]=aa_feval(mfile_alias,aap,task,i,j);
                                    if (length(resp)>0)
                                        aas_log(aap,0,['\n***WARNING: ' resp]);
                                    end;
                                case 'doit'
                                    tic
                                    % before starting current stage, delete done_
                                    % flag for next one
                                    for k0i=1:length(aap.internal.outputstreamdestinations{k}.stream)
                                        aas_delete_doneflag(aap,aap.internal.outputstreamdestinations{k}.stream(k0i).destnumber,i,j);
                                    end;
                                    
                                    % work out what needs to be done before we can
                                    % execute this stage
                                    completefirst=aap.internal.inputstreamsources{k}.stream;
                                    tbcf=[];
                                    for k0i=1:length(completefirst)
                                        switch(completefirst(k0i).sourcedomain)
                                            case 'study'
                                                tbcf={aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber)};
                                            case 'subject'
                                                tbcf=[tbcf {aas_doneflag_getpath(aap,i,completefirst(k0i).sourcenumber)}];
                                            case 'session'
                                                tbcf=[tbcf {aas_doneflag_getpath(aap,i,j,completefirst(k0i).sourcenumber)}];
                                            case 'internal'
                                                % Get parallel parts of stage on
                                                % which this one is dependent
                                                loopvar=getparallelparts(aap,k0i);
                                                for x=1:length(loopvar)
                                                    if ischar(loopvar{x})
                                                        previousdoneflag=fullfile(aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber),[loopvar{x} '.done']); % file in directory
                                                    elseif isstruct(loopvar{x})
                                                        try c={loopvar{x}.id};
                                                        catch c=strcat(struct2cell(loopvar{x}),'.'); % Convert structure to cell
                                                        end
                                                        previousdoneflag=fullfile(aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber),[c{:} 'done']); % file in directory
                                                    end
                                                    tbcf=[tbcf {previousdoneflag}];
                                                end
                                        end;
                                    end;
                                    taskmask.tobecompletedfirst=tbcf;
                                    
                                    % now queue current stage
                                    aas_log(aap,0,sprintf('MODULE %s PENDING: %s for %s',stagename,description,aas_getsessname(aap,i,j)));
                                    taskmask.i=i;
                                    taskmask.j=j;
                                    taskmask.description=sprintf('%s for %s',description,aas_getsessname(aap,i,j));
                                    taskmask.doneflag=doneflag;
                                    
                                    taskqueue.addtask(taskmask);
                            end;
                        end;
                    end;
                end;
                if (strcmp(task,'doit'))
                    
                    if (alldone)
                        aas_log(aap,false,sprintf('- done: %s for all sessions of all subjects',description));
                    else
                        if (length(msg)>2)
                            msg=msg(1:length(msg-2));
                        end;
                        aas_log(aap,false,msg);
                    end;
                end;
                
            case 'internal' % e.g. for parallelising contrasts at group level [djm]
                switch (task)
                    case 'checkrequirements'
                        [aap,resp]=aa_feval(mfile_alias,aap,task);
                        if (length(resp)>0)
                            aas_log(aap,0,['\n***WARNING: ' resp]);
                        end;
                    case 'doit'
                        % work out what needs to be done before we can
                        % execute this stage
                        completefirst=aap.internal.inputstreamsources{k}.stream;
                        tbcf=[];
                        % allow multiple dependecies
                        for k0i=1:length(completefirst)
                            switch(completefirst(k0i).sourcedomain)
                                case 'study'
                                    tbcf={aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber)};
                                case 'subject'
                                    for i=1:length(aap.acq_details.subjects)
                                        tbcf=[tbcf {aas_doneflag_getpath(aap,i,completefirst(k0i).sourcenumber)}];
                                    end;
                                case 'session'
                                    for i=1:length(aap.acq_details.subjects)
                                        for j=aap.acq_details.selected_sessions
                                            tbcf=[tbcf {aas_doneflag_getpath(aap,i,j,completefirst(k0i).sourcenumber)}];
                                        end;
                                    end;
                                case 'internal'
                                    % Get parallel parts of stage on
                                    % which this one is dependent
                                    loopvar=getparallelparts(aap,k0i);
                                    for x=1:length(loopvar)
                                        if ischar(loopvar{x})
                                            previousdoneflag=fullfile(aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber),[loopvar{x} '.done']); % file in directory
                                        elseif isstruct(loopvar{x})
                                            try c={loopvar{x}.id};
                                            catch c=strcat(struct2cell(loopvar{x}),'.'); % Convert structure to cell
                                            end
                                            previousdoneflag=fullfile(aas_doneflag_getpath(aap,completefirst(k0i).sourcenumber),[c{:} 'done']); % file in directory
                                        end
                                        tbcf=[tbcf {previousdoneflag}];
                                    end
                            end;
                        end;
                        doneflag=aas_doneflag_getpath(aap,k);% this will be a directory
                        % Get parallel parts of the current
                        % stage
                        loopvar=getparallelparts(aap,k);
                        for x=1:length(loopvar)
                            if ischar(loopvar{x})
                                doneflag=fullfile(aas_doneflag_getpath(aap,k),[loopvar{x} '.done']); % file in directory
                                desc=loopvar{x};
                            elseif isstruct(loopvar{x})
                                try c={loopvar{x}.id};
                                catch c=strcat(struct2cell(loopvar{x}),'.'); % Convert structure to cell
                                end
                                doneflag=fullfile(aas_doneflag_getpath(aap,k),[c{:} 'done']); % file in directory
                                desc=[c{:}];
                            end
                            if (aas_doneflagexists(aap,doneflag))
                                aas_log(aap,0,sprintf('- done: %s for %s',stagename,desc));
                            else
                                % before starting current stage, delete done_
                                % flag for next one
                                for k0i=1:length(aap.internal.outputstreamdestinations{k}.stream)
                                    aas_delete_doneflag(aap,aap.internal.outputstreamdestinations{k}.stream(k0i).destnumber,i);
                                end;
                                
                                % now queue current stage
                                aas_log(aap,0,sprintf('MODULE %s PENDING: for %s',stagename,desc));
                                taskmask.i=loopvar{x};
                                taskmask.j=0;
                                taskmask.doneflag=doneflag;
                                taskmask.tobecompletedfirst=tbcf;
                                taskmask.description=sprintf('%s for %s',description,desc);
                                taskqueue.addtask(taskmask);
                            end;
                        end
                end;
                
            otherwise
                aas_log(aap,1,sprintf('Unknown domain %s associated with stage %s - check the domain="xxx" field in the .xml file associated with this module',domain,aap.tasklist.main.module(k).name));
        end;
        % Get jobs started as quickly as possible - important on AWS as it
        % can take a while to scan all of the done flags
        taskqueue.runall(dontcloseexistingworkers);
    end;
end;


% Moved back to python as this thread doesn't have permissions to the queue
% if (exist('receipthandle','var'))
%     aas_log(aap,0,sprintf('Have run all jobs, now trying to delete message in queue %s with receipt handle %s.',aaworker.aapqname,receipthandle));
%     sqs_delete_message(aap,aaworker.aapqname,receipthandle);
% end;
% aas_log(aap,0,'Message deleted');

return;






%% BUILD DEPENDENCY MAP
function [aap]=builddependencymap(aap)

aap.internal.dependenton=cell(length(aap.tasklist.main.module),1);
aap.internal.dependencyof=cell(length(aap.tasklist.main.module),1);

for k1=1:length(aap.tasklist.main.module)
    % Default is no dependencies
    completefirst=[];
    
    % first stage has no dependencies
    if (k1>1)
        
        tobecompletedfirst=aap.tasklist.main.module(k1).tobecompletedfirst;
        
        % Defaults to previous stage
        if (isempty(tobecompletedfirst))
            tobecompletedfirst={'[previous]'};
        end;
        if (~iscell(tobecompletedfirst) && ~isempty(tobecompletedfirst))
            tobecompletedfirst={tobecompletedfirst};
        end;
        
        for k0i=1:length(tobecompletedfirst)
            % previous stage, or something elsE?
            if (strcmp(tobecompletedfirst{k0i},'[previous]'))  % empty now same as [previous]
                completefirst(k0i).stage=k1-1;
            elseif (strcmp(tobecompletedfirst{k0i},'[none]'))   %... so none must be explcitly specified
            else
                for k0=1:k1
                    % allow full path of module to be provided
                    stagetag=aas_getstagetag(aap,k0);
                    if strcmp(stagetag,tobecompletedfirst{k0i})
                        break;
                    end;
                    if (k0==k1)
                        aas_log(aap,1,sprintf('%s is only to be executed after %s, but this is not in the task list',aap.tasklist.main.module(k1).name,tobecompletedfirst{k0i}));
                    end;
                end;
                completefirst(k0i).stage=k0;
            end;
            % now find out what domain the done flags need to cover
            % allow full path of module to be provided
            [stagepath stagename]=fileparts(aap.tasklist.main.module(completefirst(k0i).stage).name);
            completefirst(k0i).sourcedomain=aap.schema.tasksettings.(stagename)(aap.tasklist.main.module(completefirst(k0i).stage).index).ATTRIBUTE.domain;
        end;
        
        aap.internal.dependenton{k1}=completefirst;
        
        % now produce indexing the other way, to map
        % aap.internal.dependencyof
        [stagepath stagename]=fileparts(aap.tasklist.main.module(k1).name);
        thisstage=[];
        thisstage.stage=k1;
        thisstage.domain=aap.schema.tasksettings.(stagename)(aap.tasklist.main.module(k1).index).ATTRIBUTE.domain;
        for k0i=1:length(completefirst)
            aap.internal.dependencyof{completefirst(k0i).stage}=[aap.internal.dependencyof{completefirst(k0i).stage} thisstage];
        end;
    end;
    
end;


%% CONNECT DATA PIPELINE BY IDENTIFYING SOURCE OF INPUT FROM OUTPUT STREAMS
%   Works back through dependencies to determine where inputs come from
function [aap]=findinputstreamsources(aap)

% Make empty cell structures for input and output streams
aap.internal.inputstreamsources=cell(length(aap.tasklist.main.module),1);
aap.internal.outputstreamdestinations=cell(length(aap.tasklist.main.module),1);
for k1=1:length(aap.tasklist.main.module)
    aap.internal.inputstreamsources{k1}.stream=[];
    aap.internal.outputstreamdestinations{k1}.stream=[];
end;

% Now go through each module and find its input dependencies
%  then make bi-directional connections in inputstreamsources and
%  outputstreamdestinations
for k1=1:length(aap.tasklist.main.module)
    [stagepath stagename]=fileparts(aap.tasklist.main.module(k1).name);
    index=aap.tasklist.main.module(k1).index;
    if (isfield(aap.schema.tasksettings.(stagename),'inputstreams'))
        inputstreams=aap.schema.tasksettings.(stagename).inputstreams;
        
        for i=1:length(inputstreams.stream)
            [aap stagethatoutputs mindepth]=searchforoutput(aap,k1,inputstreams.stream{i},true,0,inf);
            if isempty(stagethatoutputs)
                aas_log(aap,false,sprintf('Stage %s required input %s is not an output of any stage it is dependent on - so hopefully a primary input?',stagename,inputstreams.stream{i}));
            else
                [sourcestagepath sourcestagename]=fileparts(aap.tasklist.main.module(stagethatoutputs).name);
                sourceindex=aap.tasklist.main.module(stagethatoutputs).index;
                aas_log(aap,false,sprintf('Stage %s input %s comes from %s which is %d dependencies prior',stagename,inputstreams.stream{i},sourcestagename,mindepth));
                stream=[];
                stream.name=inputstreams.stream{i};
                stream.sourcenumber=stagethatoutputs;
                stream.sourcestagename=sourcestagename;
                stream.depth=mindepth;
                stream.sourcedomain=aap.schema.tasksettings.(sourcestagename)(sourceindex).ATTRIBUTE.domain;
                if (isempty(aap.internal.inputstreamsources{k1}.stream))
                    aap.internal.inputstreamsources{k1}.stream=stream;
                else
                    aap.internal.inputstreamsources{k1}.stream(end+1)=stream;
                end;
                
                stream=[];
                stream.name=inputstreams.stream{i};
                stream.destnumber=k1;
                stream.deststagename=stagename;
                stream.depth=mindepth;
                stream.destdomain=aap.schema.tasksettings.(stagename)(index).ATTRIBUTE.domain;
                if (isempty(aap.internal.outputstreamdestinations{stagethatoutputs}.stream))
                    aap.internal.outputstreamdestinations{stagethatoutputs}.stream=stream;
                else
                    aap.internal.outputstreamdestinations{stagethatoutputs}.stream(end+1)=stream;
                end;
            end;
        end;
    end;
end;


% RECURSIVELY SEARCH DEPENDENCIES
%  to see which will have outputted each
%  input required for this stage
%  note that inputs can be affected by dependency map
function [aap,stagethatoutputs,mindepth]=searchforoutput(aap,currentstage,outputtype,notthislevelplease,depth,mindepth)

% is this branch ever going to do better than we already have?
if (depth>=mindepth)
    return;
end;

stagethatoutputs=[];

% Search the current level, see if it provides the required output
if (~notthislevelplease)
    depth=depth+1;
    [stagepath stagename]=fileparts(aap.tasklist.main.module(currentstage).name);
    stagetag=aas_getstagetag(aap,currentstage);
    index=aap.tasklist.main.module(currentstage).index;
    
    if (isfield(aap.schema.tasksettings.(stagename)(index),'outputstreams'))
        outputstreams=aap.schema.tasksettings.(stagename)(index).outputstreams;
        for i=1:length(outputstreams.stream)
            if (strcmp(outputtype,outputstreams.stream{i}) || strcmp(outputtype,[stagetag '.' outputstreams.stream{i}]))
                stagethatoutputs=currentstage;
                mindepth=depth;
            end;
        end;
    end;
end;

% If not found, search backwards further
if (isempty(stagethatoutputs))
    dependenton=aap.internal.dependenton{currentstage};
    for i=1:length(dependenton)
        [aap stagethatoutputs mindepth]=searchforoutput(aap,dependenton(i).stage,outputtype,false,depth,mindepth);
    end;
end;



function [loopvar]=getparallelparts(aap,stagenum)
[prev_stagepath prev_stagename]=fileparts(aap.tasklist.main.module(stagenum).name);
prev_index=aap.tasklist.main.module(stagenum).index;
if (isfield(aap.schema.tasksettings.(prev_stagename)(prev_index).ATTRIBUTE,'mfile_alias'))
    prev_mfile_alias=aap.schema.tasksettings.(prev_stagename)(prev_index).ATTRIBUTE.mfile_alias;
else
    prev_mfile_alias=prev_stagename;
end;
[aap,loopvar]=aa_feval(prev_mfile_alias,aap,'getparallelparts');


