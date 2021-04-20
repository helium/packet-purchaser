%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.17.0

-ifndef(fuota).
-define(fuota, true).

-define(fuota_gpb_version, "4.17.0").

-ifndef('FUOTA.DEPLOYMENTDEVICE_PB_H').
-define('FUOTA.DEPLOYMENTDEVICE_PB_H', true).
-record('fuota.DeploymentDevice',
    % = 1, optional
    {dev_eui = <<>> :: iodata() | undefined,
        % = 2, optional
        mc_root_key = <<>> :: iodata() | undefined}
).
-endif.

-ifndef('FUOTA.DEPLOYMENT_PB_H').
-define('FUOTA.DEPLOYMENT_PB_H', true).
-record('fuota.Deployment',
    % = 1, optional, 64 bits
    {application_id = 0 :: integer() | undefined,
        % = 2, repeated
        devices = [] :: [fuota:'fuota.DeploymentDevice'()] | undefined,
        % = 3, optional, enum fuota.MulticastGroupType
        multicast_group_type = 'CLASS_B' :: 'CLASS_B' | 'CLASS_C' | integer() | undefined,
        % = 4, optional, 32 bits
        multicast_dr = 0 :: non_neg_integer() | undefined,
        % = 5, optional, 32 bits
        multicast_ping_slot_period = 0 :: non_neg_integer() | undefined,
        % = 6, optional, 32 bits
        multicast_frequency = 0 :: non_neg_integer() | undefined,
        % = 7, optional, 32 bits
        multicast_group_id = 0 :: non_neg_integer() | undefined,
        % = 8, optional, 32 bits
        multicast_timeout = 0 :: non_neg_integer() | undefined,
        % = 9, optional
        unicast_timeout = undefined :: fuota:'google.protobuf.Duration'() | undefined,
        % = 10, optional, 32 bits
        unicast_attempt_count = 0 :: non_neg_integer() | undefined,
        % = 11, optional, 32 bits
        fragmentation_fragment_size = 0 :: non_neg_integer() | undefined,
        % = 12, optional
        payload = <<>> :: iodata() | undefined,
        % = 13, optional, 32 bits
        fragmentation_redundancy = 0 :: non_neg_integer() | undefined,
        % = 14, optional, 32 bits
        fragmentation_session_index = 0 :: non_neg_integer() | undefined,
        % = 15, optional, 32 bits
        fragmentation_matrix = 0 :: non_neg_integer() | undefined,
        % = 16, optional, 32 bits
        fragmentation_block_ack_delay = 0 :: non_neg_integer() | undefined,
        % = 17, optional
        fragmentation_descriptor = <<>> :: iodata() | undefined}
).
-endif.

-ifndef('FUOTA.CREATEDEPLOYMENTREQUEST_PB_H').
-define('FUOTA.CREATEDEPLOYMENTREQUEST_PB_H', true).
-record('fuota.CreateDeploymentRequest',
    % = 1, optional
    {deployment = undefined :: fuota:'fuota.Deployment'() | undefined}
).
-endif.

-ifndef('FUOTA.CREATEDEPLOYMENTRESPONSE_PB_H').
-define('FUOTA.CREATEDEPLOYMENTRESPONSE_PB_H', true).
-record('fuota.CreateDeploymentResponse',
    % = 1, optional
    {id = <<>> :: iodata() | undefined}
).
-endif.

-ifndef('FUOTA.GETDEPLOYMENTSTATUSREQUEST_PB_H').
-define('FUOTA.GETDEPLOYMENTSTATUSREQUEST_PB_H', true).
-record('fuota.GetDeploymentStatusRequest',
    % = 1, optional
    {id = <<>> :: iodata() | undefined}
).
-endif.

-ifndef('FUOTA.DEPLOYMENTDEVICESTATUS_PB_H').
-define('FUOTA.DEPLOYMENTDEVICESTATUS_PB_H', true).
-record('fuota.DeploymentDeviceStatus',
    % = 1, optional
    {dev_eui = <<>> :: iodata() | undefined,
        % = 2, optional
        created_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 3, optional
        updated_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 4, optional
        mc_group_setup_completed_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 5, optional
        mc_session_completed_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 6, optional
        frag_session_setup_completed_at = undefined ::
            fuota:'google.protobuf.Timestamp'() | undefined,
        % = 7, optional
        frag_status_completed_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined}
).
-endif.

-ifndef('FUOTA.GETDEPLOYMENTSTATUSRESPONSE_PB_H').
-define('FUOTA.GETDEPLOYMENTSTATUSRESPONSE_PB_H', true).
-record('fuota.GetDeploymentStatusResponse',
    % = 1, optional
    {created_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 2, optional
        updated_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 3, optional
        mc_group_setup_completed_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 4, optional
        mc_session_completed_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 5, optional
        frag_session_setup_completed_at = undefined ::
            fuota:'google.protobuf.Timestamp'() | undefined,
        % = 6, optional
        enqueue_completed_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 7, optional
        frag_status_completed_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 8, repeated
        device_status = [] :: [fuota:'fuota.DeploymentDeviceStatus'()] | undefined}
).
-endif.

-ifndef('FUOTA.GETDEPLOYMENTDEVICELOGSREQUEST_PB_H').
-define('FUOTA.GETDEPLOYMENTDEVICELOGSREQUEST_PB_H', true).
-record('fuota.GetDeploymentDeviceLogsRequest',
    % = 1, optional
    {deployment_id = <<>> :: iodata() | undefined,
        % = 2, optional
        dev_eui = <<>> :: iodata() | undefined}
).
-endif.

-ifndef('FUOTA.DEPLOYMENTDEVICELOG_PB_H').
-define('FUOTA.DEPLOYMENTDEVICELOG_PB_H', true).
-record('fuota.DeploymentDeviceLog',
    % = 1, optional
    {created_at = undefined :: fuota:'google.protobuf.Timestamp'() | undefined,
        % = 2, optional, 32 bits
        f_port = 0 :: non_neg_integer() | undefined,
        % = 3, optional
        command = [] :: unicode:chardata() | undefined,
        % = 4
        fields = [] :: [{unicode:chardata(), unicode:chardata()}] | undefined}
).
-endif.

-ifndef('FUOTA.GETDEPLOYMENTDEVICELOGSRESPONSE_PB_H').
-define('FUOTA.GETDEPLOYMENTDEVICELOGSRESPONSE_PB_H', true).
-record('fuota.GetDeploymentDeviceLogsResponse',
    % = 1, repeated
    {logs = [] :: [fuota:'fuota.DeploymentDeviceLog'()] | undefined}
).
-endif.

-ifndef('GOOGLE.PROTOBUF.TIMESTAMP_PB_H').
-define('GOOGLE.PROTOBUF.TIMESTAMP_PB_H', true).
-record('google.protobuf.Timestamp',
    % = 1, optional, 64 bits
    {seconds = 0 :: integer() | undefined,
        % = 2, optional, 32 bits
        nanos = 0 :: integer() | undefined}
).
-endif.

-ifndef('GOOGLE.PROTOBUF.DURATION_PB_H').
-define('GOOGLE.PROTOBUF.DURATION_PB_H', true).
-record('google.protobuf.Duration',
    % = 1, optional, 64 bits
    {seconds = 0 :: integer() | undefined,
        % = 2, optional, 32 bits
        nanos = 0 :: integer() | undefined}
).
-endif.

-endif.