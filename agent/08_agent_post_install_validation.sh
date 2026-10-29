#!/usr/bin/env bash
set -euxo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"

LOGDIR="${SCRIPTDIR}/logs"
source "$SCRIPTDIR/logging.sh"
source "$SCRIPTDIR/common.sh"

if [[ "${AGENT_E2E_TEST_BOOT_MODE}" == "ISO_NO_REGISTRY" ]]; then
    MAX_ATTEMPTS=120
    SLEEP_SECONDS=30  # Wait time between connection attempts
    ATTEMPT_COUNT=0

    echo "Starting oc wait retry loop for API connection up to 60 minutes..."
    set +x  # Disable debug tracing for cleaner output
    while ! oc wait clusterversion version --for=condition=Available=True --timeout=1s 2>/dev/null; do
        ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
        if [ $ATTEMPT_COUNT -ge $MAX_ATTEMPTS ]; then
            echo ""
            set -x  # Re-enable debug tracing
            echo "ERROR: API server connection failed after $MAX_ATTEMPTS attempts over 60 minutes."
            exit 1
        fi

        echo -n "."
        sleep $SLEEP_SECONDS
    done
    echo ""
    set -x  # Re-enable debug tracing
    echo "SUCCESS: API server connection established and ClusterVersion is available."
    # Run subsequent commands after successful cluster setup
    oc get packagemanifests -n openshift-marketplace
fi

installed_control_plane_nodes=$(oc get nodes --selector=node-role.kubernetes.io/master | grep -cv AGE)

oc get nodes

if (( NUM_MASTERS != installed_control_plane_nodes )); then
  echo "Post install validation failed. Expected $NUM_MASTERS control plane nodes but found $installed_control_plane_nodes."
  exit 1
fi

oc get clusterversion

if [[ "${AGENT_INFRA_TOPOLOGY:-}" == "SingleReplica" ]]; then
  echo "Enabling MutableTopology feature gate via CustomNoUpgrade featureSet..."

  # Allow all workers to update simultaneously to avoid PDB drain deadlock
  if (( NUM_WORKERS > 1 )); then
    oc patch mcp worker --type merge -p "{\"spec\":{\"maxUnavailable\":${NUM_WORKERS}}}"
  fi

  oc patch featuregate cluster --type merge -p \
    '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["MutableTopology"]}}}'

  echo "Waiting for MCP updates to complete (this may take 20+ minutes)..."
  sleep 60
  oc wait mcp master worker --for=condition=Updated=True --timeout=40m

  # Restore default maxUnavailable
  if (( NUM_WORKERS > 1 )); then
    oc patch mcp worker --type merge -p '{"spec":{"maxUnavailable":1}}'
  fi

  echo "Patching infrastructure topology to SingleReplica..."
  oc patch infrastructure cluster --type merge --subresource status -p \
    '{"status":{"infrastructureTopology":"SingleReplica"}}'

  echo "Verifying infrastructure topology..."
  infra_topology=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureTopology}')
  if [[ "${infra_topology}" != "SingleReplica" ]]; then
    echo "ERROR: Infrastructure topology is '${infra_topology}', expected 'SingleReplica'"
    exit 1
  fi
  echo "Infrastructure topology correctly set to SingleReplica"
fi
