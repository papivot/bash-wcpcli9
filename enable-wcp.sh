#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Define a function for logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

###################################################
# Enter Infrastructure variables here
###################################################
VCENTER_VERSION=9
VCENTER_HOSTNAME=192.168.100.50
VCENTER_USERNAME=administrator@vsphere.local
VCENTER_PASSWORD='VMware1!'
NSX_MANAGER=192.168.100.57
NSX_USERNAME='admin'
NSX_PASSWORD='VMware123!VMware123!'

DEPLOYMENT_TYPE='FLB' # Allowed values are VPC, NSX, AVI, FLB  

#####################################################
# Common variables
#####################################################
export DNS_SERVER='10.6.248.74'
export NTP_SERVER='10.6.248.74'
export DNS_SEARCHDOMAIN='env1.lab.test'
export MGMT_STARTING_IP='192.168.100.60'
export MGMT_GATEWAY_CIDR='192.168.100.1/23'
export K8S_SERVICE_SUBNET='10.96.0.0'
export K8S_SERVICE_SUBNET_COUNT=512 # Allowed values are 256, 512, 1024, 2048, 4096...
export SUPERVISOR_NAME='supervisorCluster0'
export SUPERVISOR_SIZE=TINY # Allowed values are TINY, SMALL, MEDIUM, LARGE 
export SUPERVISOR_VM_COUNT=1 # Allowed values are 1, 3
K8S_SUP_CLUSTER=Cluster
K8S_MGMT_PORTGROUP1='DVPG-Mgmt-PG'
K8S_WKD0_PORTGROUP='Workload0-VDS-PG' # Not needed for NSX
K8S_STORAGE_POLICY='vSAN Default Storage Policy'

###############################################################
# AVI specific variables
###############################################################
#export AVI_CONTROLLER='192.168.100.58'
#export AVI_CLOUD='domain-c10'
#export AVI_USERNAME=admin
#export AVI_PASSWORD='VMware123!VMware123!'
#export AVI_WORKLOAD_NW_GATEWAY_CIDR='192.168.102.1/23'
#export AVI_WORKLOAD_STARTING_IP='192.168.102.100'
#export AVI_WORKLOAD_IP_COUNT=64

###############################################################
# FLB specific variables
###############################################################
export FLB_MANAGEMENT_STARTING_IP='192.168.100.165'
export FLB_MANAGEMENT_IP_COUNT=2
export FLB_NW_STARTING_IP='192.168.102.10'
export FLB_NW_IP_COUNT=2
export FLB_VIP_STARTING_IP='192.168.102.50'
export FLB_VIP_IP_COUNT=50
export FLB_WORKLOAD_NW_GATEWAY_CIDR='192.168.102.1/23'
export FLB_WORKLOAD_NW_STARTING_IP='192.168.102.100'
export FLB_WORKLOAD_IP_COUNT=64

#############################################################
# NSX specific variables
#############################################################
#export NSX_EDGE_CLUSTER='edge-cluster-01'
#export NSX_T0_GATEWAY='t0-01'
#export NSX_DVS_PORTGROUP='vds1'
#export NSX_INGRESS_NW='10.220.3.16'
#export NSX_INGRESS_COUNT=16
#export NSX_EGRESS_NW='10.220.30.80'
#export NSX_EGRESS_COUNT=16
#export NSX_NAMESPACE_NW='10.244.0.0'
#export NSX_NAMESPACE_COUNT=4096

#############################################################
# VPC-specific variables
#############################################################
#export VPC_ORG='default'
#export VPC_PROJECT='default'
#export VPC_CONNECTIVITY_PROFILE='vpc_connectivity_profile-default'
#export VPC_DEFAULT_PRIVATE_CIDRS_ADDRESS='10.1.240.128'
#export VPC_DEFAULT_PRIVATE_CIDRS_PREFIX=25

################################################
# Check if jq is installed
################################################
log "Starting pre-flight checks..."
for cmd in jq curl openssl mktemp; do
        if command -v '${cmd}' &> /dev/null; then
                log "ERROR: Required command '${cmd}' could not be found. Please install it to run this script."
                exit 1
        fi
done

if [ ${DEPLOYMENT_TYPE} == "AVI" ]
then
        cp enable_on_cc_avi.json cluster.json
elif [ ${DEPLOYMENT_TYPE} == "VPC" ]
then
        cp enable_on_cc_vpc.json cluster.json
elif [ ${DEPLOYMENT_TYPE} == "NSX" ]
then
        cp enable_on_cc_nsx.json cluster.json
elif [ ${DEPLOYMENT_TYPE} == "FLB" ]
then
        cp enable_on_cc_flb.json cluster.json
else
        log "ERROR: Invalid DEPLOYMENT_TYPE: '${DEPLOYMENT_TYPE}'. Allowed values are VPC, NSX, AVI, FLB."
        exit 1
fi  

################################################
# Login to VCenter and get Session ID
###############################################
log "Attempting to authenticate to vCenter Server: ${VCENTER_HOSTNAME}..."
HEADER_CONTENTTYPE="Content-Type: application/json"
SESSION_ID=$(curl -sk -X POST https://${VCENTER_HOSTNAME}/rest/com/vmware/cis/session --user ${VCENTER_USERNAME}:${VCENTER_PASSWORD} |jq -r '.value')
if [ -z "${SESSION_ID}" ]
then
        log "ERROR: Failed to make vCenter session API call."
        exit 1
fi
log "Successfully authenticated to vCenter. Session ID obtained."
HEADER_SESSIONID="vmware-api-session-id: ${SESSION_ID}"

################################################
# Get cluster details from vCenter
###############################################
log "Searching for Cluster ${K8S_SUP_CLUSTER} ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/cluster --output /tmp/temp_cluster.json)
if [[ "${response}" -ne 200 ]] ; then
  log "Error: Could not fetch clusters. Please validate!!"
  exit 1
fi

export VKSClusterID=$(jq -r --arg K8S_SUP_CLUSTER "$K8S_SUP_CLUSTER" '.[]|select(.name == $K8S_SUP_CLUSTER).cluster' /tmp/temp_cluster.json)
#export VKSClusterID=$(jq -r --arg K8S_SUP_CLUSTER "$K8S_SUP_CLUSTER" '.[]|select(.name|contains($K8S_SUP_CLUSTER)).cluster' /tmp/temp_cluster.json)
if [ -z "${VKSClusterID}" ]
then
        log "Error: Could not fetch cluster - ${K8S_SUP_CLUSTER} . Please validate!!"
        exit 1
fi

################################################
# Get storage policy details from vCenter
###############################################
log "Searching for Storage Policy ${K8S_STORAGE_POLICY} ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/storage/policies --output /tmp/temp_storagepolicies.json)
if [[ "${response}" -ne 200 ]] ; then
  log "Error: Could not fetch storage policy. Please validate!!"
  exit 1
fi

export VKS_STORAGE_POLICY=$(jq -r --arg K8S_STORAGE_POLICY "$K8S_STORAGE_POLICY" '.[]| select(.name == $K8S_STORAGE_POLICY)|.policy' /tmp/temp_storagepolicies.json)
#export TKGStoragePolicy=$(jq -r --arg K8S_STORAGE_POLICY "$K8S_STORAGE_POLICY" '.[]| select(.name|contains($K8S_STORAGE_POLICY))|.policy' /tmp/temp_storagepolicies.json)
if [ -z "${VKS_STORAGE_POLICY}" ]
then
        log "Error: Could not fetch storage policy - ${K8S_STORAGE_POLICY} . Please validate!!"
        exit 1
fi

################################################
# Get network details from vCenter
###############################################
log "Searching for Network portgroup ${K8S_MGMT_PORTGROUP1} ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/network --output /tmp/temp_networkportgroups.json)
if [[ "${response}" -ne 200 ]] ; then
  log "Error: Could not fetch network details. Please validate!!"
  exit 1
fi

export VKS_MGMT_NETWORK1=$(jq -r --arg K8S_MGMT_PORTGROUP1 "$K8S_MGMT_PORTGROUP1" '.[]| select(.name == $K8S_MGMT_PORTGROUP1)|.network' /tmp/temp_networkportgroups.json)
export VKS_WKLD_NETWORK=$(jq -r --arg K8S_WKD0_PORTGROUP "$K8S_WKD0_PORTGROUP" '.[]| select(.name == $K8S_WKD0_PORTGROUP)|.network' /tmp/temp_networkportgroups.json)

if [ -z "${VKS_MGMT_NETWORK1}" ]
then
        log "Error: Could not fetch portgroup - ${K8S_MGMT_PORTGROUP1} . Please validate!!"
        exit 1
fi

################################################
# Get NSXALB CA CERT
###############################################
if [ ${DEPLOYMENT_TYPE} == "AVI" ]
then
        log "Getting NSX ALB CA Certificate for  ${AVI_CONTROLLER} ..."
        openssl s_client -showcerts -connect ${AVI_CONTROLLER}:443  </dev/null 2>/dev/null|sed -ne '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > /tmp/temp_avi-ca.cert
        if [ ! -s /tmp/temp_avi-ca.cert ]
        then
                log "Error: Could not connect to the NSX ALB endpoint. Please validate!!"
                exit 1
        fi
        export AVI_CACERT=$(jq -sR . /tmp/temp_avi-ca.cert)
        
        if [ -z "${VKS_WKLD_NETWORK}" ]
        then
                log "Error: Could not fetch portgroup - ${K8S_WKD0_PORTGROUP} . Please validate!!"
                exit 1
        fi
fi

################################################
# Complete NSX-specific processing
###############################################
if [ ${DEPLOYMENT_TYPE} == "NSX" ]
then
        ################################################
        # Get NSX VDS from vCenter
        ###############################################
        log "Searching for NSX compatible VDS switch ..."
        response=$(curl -ks --write-out "%{http_code}" -X POST  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/namespace-management/networks/nsx/distributed-switches?action=check_compatibility --output /tmp/temp_vds.json)
        if [[ "${response}" -ne 200 ]] ; then
                log "Error: Could not fetch VDS details. Please validate!!"
                exit 1
        fi
        export NSX_DVS=$(jq -r --arg NSX_DVS_PORTGROUP "$NSX_DVS_PORTGROUP" '.[]| select((.compatible==true) and .name == $NSX_DVS_PORTGROUP)|.distributed_switch' /tmp/temp_vds.json)
        if [ -z "${NSX_DVS}" ]
        then
                log "Error: Could not fetch NSX compatible VDS - ${NSX_DVS_PORTGROUP} . Please validate!!"
                exit 1
        fi

        ################################################
        # Get a Edge cluster ID from NSX Manager
        ###############################################
        log "Searching for Edge cluster in NSX Manager ..."
	response=$(curl -ks --write-out "%{http_code}" -X GET -u "${NSX_USERNAME}:${NSX_PASSWORD}" -H 'Content-Type: application/json' https://${NSX_MANAGER}/api/v1/edge-clusters --output /tmp/temp_edgeclusters.json)
        if [[ "${response}" -ne 200 ]] ; then
                log "Error: Could not fetch Edge Cluster details. Please validate!!"
                exit 1
	    fi
	    export NSX_EDGE_CLUSTER_ID=$(jq -r --arg NSX_EDGE_CLUSTER "$NSX_EDGE_CLUSTER" '.results[] | select( .display_name == $NSX_EDGE_CLUSTER)|.id' /tmp/temp_edgeclusters.json)
        if [ -z "${NSX_EDGE_CLUSTER_ID}" ]
        then
                log "Error: Could not fetch NSX Edge cluster - ${NSX_EDGE_CLUSTER} . Please validate!!"
                exit 1
        fi

        ################################################
        # Get a Tier0 ID from NSX Manager
        ###############################################
        log "Searching for Tier0 in NSX Manager ..."
	response=$(curl -ks --write-out "%{http_code}" -X GET -u "${NSX_USERNAME}:${NSX_PASSWORD}" -H 'Content-Type: application/json' https://${NSX_MANAGER}/policy/api/v1/infra/tier-0s --output /tmp/temp_t0s.json)
        if [[ "${response}" -ne 200 ]] ; then
                log "Error: Could not fetch Tier0 details. Please validate!!"
                exit 1
	    fi
	    export NSX_T0_GATEWAY_ID=$(jq -r --arg NSX_T0_GATEWAY "$NSX_T0_GATEWAY" '.results[] | select( .display_name == $NSX_T0_GATEWAY)|.id' /tmp/temp_t0s.json)
        if [ -z "${NSX_T0_GATEWAY_ID}" ]
        then
                log "Error: Could not fetch NSX T0 - ${NSX_T0_GATEWAY} . Please validate!!"
                exit 1
        fi
fi

################################################
# Enable Supervisor
###############################################
envsubst < cluster.json > temp_final.json
log "Enabling Supervisor cluster ${VKSClusterID}..."
curl -ks -X POST -H "${HEADER_SESSIONID}" -H "${HEADER_CONTENTTYPE}" -d "@temp_final.json" https://${VCENTER_HOSTNAME}/api/vcenter/namespace-management/supervisors/${VKSClusterID}?action=enable_on_compute_cluster

#TODO while configuring, keep checking for status of Supervisor until ready
#curl -X POST 'https://vcsa-01.lab9.com/api/vcenter/namespace-management/supervisors/domain-c10?action=enable_on_compute_cluster'
rm -f /tmp/temp_*.*
rm -f temp_final.json
rm -f cluster.json

log "Script finished successfully."
