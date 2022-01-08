ARG BASE_YUM_REPO=testing

FROM opensciencegrid/software-base:3.6-el7-${BASE_YUM_REPO}

# Previous arg has gone out of scope
ARG BASE_YUM_REPO=testing
ARG TIMESTAMP

# token auth require HTCondor 8.9.x
RUN useradd osg \
 && mkdir -p ~osg/.condor \
 && yum -y install \
        condor \
        osg-wn-client \
        redhat-lsb-core \
        singularity \
        attr \
        git \
        https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-7.16.2-x86_64.rpm \
 && yum clean all \
 && mkdir -p /etc/condor/passwords.d /etc/condor/tokens.d

# glideinwms
RUN mkdir -p /gwms/main /gwms/client /gwms/client_group_main /gwms/.gwms.d/bin /gwms/.gwms.d/exec/{cleanup,postjob,prejob,setup,setup_singularity} \
 && curl -sSfL -o /gwms/error_gen.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/error_gen.sh \
 && curl -sSfL -o /gwms/add_config_line.source https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/add_config_line.source \
 && curl -sSfL -o /gwms/.gwms.d/exec/prejob/setup_prejob.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/setup_prejob.sh \
 && curl -sSfL -o /gwms/main/singularity_setup.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/singularity_setup.sh \
 && curl -sSfL -o /gwms/main/singularity_wrapper.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/singularity_wrapper.sh \
 && curl -sSfL -o /gwms/main/singularity_lib.sh https://raw.githubusercontent.com/glideinWMS/glideinwms/branch_v3_9/creation/web_base/singularity_lib.sh \
 && curl -sSfL -o /gwms/client/stashcp http://stash.osgconnect.net/public/dweitzel/stashcp/current/stashcp \
 && chmod 755 /gwms/*.sh /gwms/main/*.sh /gwms/client/stashcp \
 && ln -s /gwms/client/stashcp /usr/bin/stashcp

# osgvo scripts
RUN curl -sSfL -o /usr/sbin/osgvo-default-image https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/node-check/osgvo-default-image \
 && curl -sSfL -o /usr/sbin/osgvo-advertise-base https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/node-check/osgvo-advertise-base \
 && curl -sSfL -o /usr/sbin/osgvo-advertise-userenv https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/node-check/osgvo-advertise-userenv \
 && curl -sSfL -o /usr/sbin/osgvo-singularity-wrapper https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/job-wrappers/default_singularity_wrapper.sh \
 && curl -sSfL -o /gwms/client_group_main/ospool-lib https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/node-check/ospool-lib \
 && curl -sSfL -o /gwms/client_group_main/singularity-extras https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/node-check/singularity-extras \
 && chmod 755 /usr/sbin/osgvo-* /gwms/client_group_main/*

COPY condor_master_wrapper /usr/sbin/
RUN chmod 755 /usr/sbin/condor_master_wrapper

RUN curl -sSfL -o /usr/libexec/condor/stash_plugin https://raw.githubusercontent.com/opensciencegrid/osg-flock/master/stashcp/stash_plugin \
 && chmod 755 /usr/libexec/condor/stash_plugin

# Override the software-base supervisord.conf to throw away supervisord logs
COPY supervisord.conf /etc/supervisord.conf

RUN git clone https://github.com/cvmfs/cvmfsexec /cvmfsexec \
 && cd /cvmfsexec \
 && ./makedist osg \
 # /cvmfs-cache and /cvmfs-logs is where the cache and logs will go; possibly bind-mounted. \
 # Needs to be 1777 so the unpriv user can use it. \
 # (Can't just chown, don't know the UID of the unpriv user.) \
 && mkdir -p /cvmfs-cache /cvmfs-logs \
 && chmod 1777 /cvmfs-cache /cvmfs-logs \
 && rm -rf dist/var/lib/cvmfs log \
 && ln -s /cvmfs-cache dist/var/lib/cvmfs \
 && ln -s /cvmfs-logs log \
 # tar up and delete the contents of /cvmfsexec so the unpriv user can extract it and own the files. \
 && tar -czf /cvmfsexec.tar.gz ./* \
 && rm -rf ./* \
 # Again, needs to be 1777 so the unpriv user can extract into it. \
 && chmod 1777 /cvmfsexec

# Space separated list of repos to mount at startup (if using cvmfsexec);
# leave this blank to disable cvmfsexec
ENV CVMFSEXEC_REPOS=
# The proxy to use for CVMFS; leave this blank to use the default
ENV CVMFS_HTTP_PROXY=
# The quota limit in MB for CVMFS; leave this blank to use the default
ENV CVMFS_QUOTA_LIMIT=


# Options to limit resource usage:
# Number of CPUs available to jobs
ENV NUM_CPUS=
# Amount of memory (in MB) available to jobs
ENV MEMORY=

# Ensure that GPU libs can be accessed by user Singularity containers
# running inside Singularity osgvo-docker-pilot containers
# (SOFTWARE-4807)
COPY ldconfig_wrapper.sh /usr/local/bin/ldconfig
COPY 10-ldconfig-cache.sh /etc/osg/image-init.d/

COPY entrypoint.sh /bin/entrypoint.sh
COPY 10-setup-htcondor.sh /etc/osg/image-init.d/
COPY 10-cleanup-htcondor.sh /etc/osg/image-cleanup.d/
COPY 10-htcondor.conf /etc/supervisord.d/
COPY 50-main.config /etc/condor/config.d/
COPY filebeat.yml /etc/filebeat/
COPY 20-filebeat.conf /etc/supervisord.d/
RUN chmod 755 /bin/entrypoint.sh

RUN if [[ -n $TIMESTAMP ]]; then \
       tag=opensciencegrid/osgvo-docker-pilot:${BASE_YUM_REPO}-${TIMESTAMP}; \
    else \
       tag=; \
    fi; \
    sed -i "s|@CONTAINER_TAG@|$tag|" \
           /etc/condor/config.d/50-main.config

RUN chown -R osg: ~osg 

RUN mkdir -p /pilot && chmod 1777 /pilot

WORKDIR /pilot
# We need an ENTRYPOINT so we can use cvmfsexec with any command (such as bash for debugging purposes)
ENTRYPOINT ["/bin/entrypoint.sh"]
# Adding ENTRYPOINT clears CMD
CMD ["/usr/local/sbin/supervisord_startup.sh"]
