% Make 2 pilab volume instances: one for the GLM specification, and another
% for its corresponding EPI volumes

function [aap,resp]=aamod_pilab_epiandmodel2volume(aap,task,subj)

resp='';

switch task
    case 'domain'
        resp='subject';   % this module needs to be run once per subject
        
    case 'description'
        resp='T map to pilab Volume';
        
    case 'summary'
        
    case 'report'
        
    case 'doit'
        % gm mask
        mpath = aas_getfiles_bystream(aap,subj,'freesurfer_gmmask');
        % (epi is second mask)
        mask = mpath(2,:);

        % model
        spmpath = aas_getfiles_bystream(aap,subj,'firstlevel_spm');
        load(spmpath);
        % convolved design matrix
        dm = SPM.xX.X;
        [nvol,nreg] = size(dm);

        % volumes
        volpaths = SPM.xY.P;
        assert(nvol == size(volpaths,1),...
            'design matrix size does not match SPM.xY.P');

        % figure out chunk data for each volume via sub2ind
        constinds = findStrInArray(SPM.xX.name,') constant');
        nruns = size(constinds,2);
        assert(nruns == length(SPM.Sess),...
            'design matrix does not match SPM.Sess length')
        [order,chunks] = ind2sub([nvol,nruns],find(dm(:,constinds)));

        % construct epi container - this can be quite slow
        fprintf('building epi volume instance...\n')
        tic;
        epivol = Volume(volpaths,mask,'chunks',chunks,'order',order);
        fprintf('finished in %s.\n',seconds2str(toc));
        % remove any voxels that == 0 at any point (likely voxels that went
        % outside the mask after realign). NaNs are unlikely but why not
        % check...
        iszero = any(epivol.data==0,1) | any(isnan(epivol.data),1);
        if any(iszero)
            % make 3D so we can revise the GM mask
            zeromask = epivol.data2mat(iszero);
            mV = spm_vol(mask);
            mxyz = spm_read_vols(mV);
            mx = (mxyz>0) & ~zeromask;
            spm_write_vol(mV,mx);
            fprintf(...
                'removed %d zero/nan features from epivol and mask\n',...
                sum(iszero));
            aap=aas_desc_outputs(aap,subj,'freesurfer_gmmask',mpath);
            % and update the volume instance
            epivol = epivol(:,~iszero);
        else
            fprintf('no zero/nan features to remove.\n') 
        end

        % construct design matrix
        % regexp to find regressor label / chunk
        labelexp = 'Sn\((?<chunk>\d+)\) (?<label>\w+)';
        % construct cell array of structs
        labarr = regexp(SPM.xX.name,labelexp,'names');
        assert(~any(cellfun(@isempty,labarr)),...
            'failed to parse regressor names')
        % pull out labels and chunks (nb, different from epi since over
        % nreg, not nvol)
        reglabels = cellfun(@(x)x.label,labarr,'uniformoutput',false);
        regchunks = cellfun(@(x)str2double(x.chunk),labarr);
        % NB, design matrix is actually transposed relative to volume (so
        % regressors in rows and volumes in columns somewhat
        % counter-intuitively).
        designvol = Volume(dm',[],'labels',reglabels,'featuregroups',...
            chunks,'names',SPM.xX.name,'chunks',regchunks);

        % save and describe
        outdir = fullfile(aas_getsubjpath(aap,subj),'pilab');
        mkdirifneeded(outdir);
        % epi
        outpath_epi = fullfile(outdir,'epivol.mat');
        % very likely too big for older Matlab formats
        save(outpath_epi,'epivol','-v7');
        aap=aas_desc_outputs(aap,subj,'pilab_epi',outpath_epi);
        % model
        outpath_design = fullfile(outdir,'designvol.mat');
        save(outpath_design,'designvol','-v7');
        aap=aas_desc_outputs(aap,subj,'pilab_design',outpath_design);
    case 'checkrequirements'
        
    otherwise
        aas_log(aap,1,sprintf('Unknown task %s',task));
end;
