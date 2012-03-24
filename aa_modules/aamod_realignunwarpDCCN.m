% AA module - realignment and unwarp
% As done at the DCCN (Donders Centre for Cognitive Neuroscience)
% [aap,resp]=aamod_realignunwarpDCCN(aap,task,p)
% Realignment using SPM5
% i=subject num
% Based on aamod_realignunwarp by Rhodri Cusack MRC CBU 2004-6
% Alejandro Vicente Grabovetsky Jan-2012

function [aap,resp]=aamod_realignunwarpDCCN(aap,task,p)

resp='';

switch task
    case 'domain'
        resp='subject';
    case 'description'
        resp='SPM5 realign and unwarp';
    case 'summary'
        resp='Done SPM5 realign and unwarp\n';
    case 'report'
        mvmean=[];
        mvmax=[];
        mvstd=[];
        mvall=[];
        nsess=length(aap.acq_details.sessions);
        
        qq=[];
        
        % @@@ NEED TO CHANGE THIS... for aa4... @@@
        for j=1:nsess
            im1fn=aas_getimages(aap,p,j,aap.tasklist.currenttask.epiprefix,aap.acq_details.numdummies,1+aap.acq_details.numdummies);
            im1V=spm_vol(im1fn);
            qq(j,:)     = spm_imatrix(im1V.mat);
            rpfn=spm_select('List',aas_getsesspath(aap,p,j),'^rp.*txt');
            mv=spm_load(fullfile(aas_getsesspath(aap,p,j),rpfn));
            mv=mv+repmat(qq(j,1:6)-qq(1,1:6),[size(mv,1) 1]);
            mv(:,4:6)=mv(:,4:6)*180/pi; % convert to degrees!
            mvmean(j,:)=mean(mv);
            mvmax(j,:)=max(mv);
            mvstd(j,:)=std(mv);
            mvall=[mvall;mv];
        end        
        
        aap.report.html=strcat(aap.report.html,'<h3>Movement maximums</h3>');
        aap.report.html=strcat(aap.report.html,'<table cellspacing="10">');
        aap.report.html=strcat(aap.report.html,sprintf('<tr><td align="right">Sess</td><td align="right">x</td><td align="right">y</td><td align="right">z</td><td align="right">rotx</td><td align="right">roty</td><td align="right">rotz</td></tr>',j));
        for j=1:nsess
            aap.report.html=strcat(aap.report.html,sprintf('<tr><td align="right">%d</td>',j));
            aap.report.html=strcat(aap.report.html,sprintf('<td align="right">%8.3f</td>',mvmax(j,:)));
            aap.report.html=strcat(aap.report.html,sprintf('</tr>',j));
        end
        aap.report.html=strcat(aap.report.html,'</table>');
        
        varcomp=mean((std(mvall).^2)./(mean(mvstd.^2)));
        aap.report.html=strcat(aap.report.html,'<h3>All variance vs. within session variance</h3><table><tr>');
        aap.report.html=strcat(aap.report.html,sprintf('<td>%8.3f</td>',varcomp));
        aap.report.html=strcat(aap.report.html,'</tr></table>');
        
        aap=aas_report_addimage(aap,fullfile(aas_getsubjpath(aap,p),'diagnostic_aamod_realign.jpg'));
        
    case 'doit'
        
        %% Set up a jobs file with some advisable defaults for realign/unwarp!
        jobs = {};
        
        % Get the options from the XML!
        jobs{1}.spatial{1}.realignunwarp.eoptions = ...
            aap.tasklist.currenttask.settings.eoptions;
        jobs{1}.spatial{1}.realignunwarp.uweptions = ...
            aap.tasklist.currenttask.settings.uweoptions;
        jobs{1}.spatial{1}.realignunwarp.uwrptions = ...
            aap.tasklist.currenttask.settings.uwroptions;
                
        % Need to place this string inside a cell?
        jobs{1}.spatial{1}.realignunwarp.eoptions.weight = ...
            {jobs{1}.spatial{1}.realignunwarp.eoptions.weight };
        
        %% Get actual data!
        
        for s = aap.acq_details.selected_sessions
            fprintf('\nGetting EPI images for session %s', aap.acq_details.sessions(s).name)
            % Get EPIs
            EPIimg = aas_getimages_bystream(aap,p,s,'epi');
            jobs{1}.spatial{1}.realignunwarp.data(s).scans = cellstr(EPIimg);
            
            % Try get VDMs
            try
                % first try to find a vdm with the session name in it
                EPIimg   = spm_select('List', ...
                    fullfile(aas_getsubjpath(aap,p), aap.directory_conventions.fieldmapsdirname), ...
                    sprintf('^vdm.*%s.nii$', aap.acq_details.sessions(s).name));
                
                % if this fails, try to get a vdm with session%d in it
                if isempty(EPIimg)
                    EPIimg   = spm_select('List', ...
                        fullfile(aas_getsubjpath(aap,p), aap.directory_conventions.fieldmapsdirname), ...
                        sprintf('^vdm.*session%d.nii$',s));
                end
                jobs{1}.spatial{1}.realignunwarp.data(s).pmscan = ...
                    cellstr(fullfile(aas_getsubjpath(aap,p), aap.directory_conventions.fieldmapsdirname, EPIimg));
                fprintf('\nFound a VDM fieldmap')
            catch
                jobs{1}.spatial{1}.realignunwarp.data(s).pmscan = ...
                    [];
                fprintf('\nWARNING: Failed to find a VDM fieldmap')
            end
        end
        
        %% Run the job!
        
        spm_jobman('run',jobs);
        
        % Save graphical output to common diagnostics directory
        if ~exist(fullfile(aap.acq_details.root, 'diagnostics'), 'dir')
            mkdir(fullfile(aap.acq_details.root, 'diagnostics'))
        end
        figure(spm_figure('FindWin'));
        [~, mriname] = fileparts(aas_getsubjpath(aap,p));
        print('-djpeg','-r75',fullfile(aap.acq_details.root, 'diagnostics', ...
            [mfilename '__' mriname '.jpeg']));
        
        %% Describe outputs
        for s = aap.acq_details.selected_sessions
            rimgs=[];
            for k=1:length(jobs{1}.spatial{1}.realignunwarp.data(s).scans);
                [pth nme ext]=fileparts(jobs{1}.spatial{1}.realignunwarp.data(s).scans{k});
                rimgs=strvcat(rimgs,fullfile(pth,['u' nme ext]));
            end
            aas_desc_outputs(aap,p,s,'epi',rimgs);
            
            % Get the realignment parameters...
            fn=dir(fullfile(pth,'rp_*.txt'));
            outpars = fullfile(pth,fn(1).name);                                   
            fn=dir(fullfile(pth,'*uw.mat'));
            outpars = strvcat(outpars, fullfile(pth,fn(1).name));
            aas_desc_outputs(aap,p,s,'realignment_parameter',outpars);
            
            if s==1
                % mean only for first session
                fn=dir(fullfile(pth,'mean*.nii'));
                aas_desc_outputs(aap,p,1,'meanepi',fullfile(pth,fn(1).name));
            end
        end
        
        time_elapsed
        
    case 'checkrequirements'
        
    otherwise
        aas_log(aap,1,sprintf('Unknown task %s',task));
end