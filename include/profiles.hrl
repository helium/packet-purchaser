%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.17.0

-ifndef(profiles).
-define(profiles, true).

-define(profiles_gpb_version, "4.17.0").

-ifndef('NS.SERVICEPROFILE_PB_H').
-define('NS.SERVICEPROFILE_PB_H', true).
-record('ns.ServiceProfile',
    % = 1, optional
    {id = <<>> :: iodata() | undefined,
        % = 2, optional, 32 bits
        ul_rate = 0 :: non_neg_integer() | undefined,
        % = 3, optional, 32 bits
        ul_bucket_size = 0 :: non_neg_integer() | undefined,
        % = 4, optional, enum ns.RatePolicy
        ul_rate_policy = 'DROP' :: 'DROP' | 'MARK' | integer() | undefined,
        % = 5, optional, 32 bits
        dl_rate = 0 :: non_neg_integer() | undefined,
        % = 6, optional, 32 bits
        dl_bucket_size = 0 :: non_neg_integer() | undefined,
        % = 7, optional, enum ns.RatePolicy
        dl_rate_policy = 'DROP' :: 'DROP' | 'MARK' | integer() | undefined,
        % = 8, optional
        add_gw_metadata = false :: boolean() | 0 | 1 | undefined,
        % = 9, optional, 32 bits
        dev_status_req_freq = 0 :: non_neg_integer() | undefined,
        % = 10, optional
        report_dev_status_battery = false :: boolean() | 0 | 1 | undefined,
        % = 11, optional
        report_dev_status_margin = false :: boolean() | 0 | 1 | undefined,
        % = 12, optional, 32 bits
        dr_min = 0 :: non_neg_integer() | undefined,
        % = 13, optional, 32 bits
        dr_max = 0 :: non_neg_integer() | undefined,
        % = 14, optional
        channel_mask = <<>> :: iodata() | undefined,
        % = 15, optional
        pr_allowed = false :: boolean() | 0 | 1 | undefined,
        % = 16, optional
        hr_allowed = false :: boolean() | 0 | 1 | undefined,
        % = 17, optional
        ra_allowed = false :: boolean() | 0 | 1 | undefined,
        % = 18, optional
        nwk_geo_loc = false :: boolean() | 0 | 1 | undefined,
        % = 19, optional, 32 bits
        target_per = 0 :: non_neg_integer() | undefined,
        % = 20, optional, 32 bits
        min_gw_diversity = 0 :: non_neg_integer() | undefined,
        % = 21, optional
        gws_private = false :: boolean() | 0 | 1 | undefined}
).
-endif.

-ifndef('NS.DEVICEPROFILE_PB_H').
-define('NS.DEVICEPROFILE_PB_H', true).
-record('ns.DeviceProfile',
    % = 1, optional
    {id = <<>> :: iodata() | undefined,
        % = 2, optional
        supports_class_b = false :: boolean() | 0 | 1 | undefined,
        % = 3, optional, 32 bits
        class_b_timeout = 0 :: non_neg_integer() | undefined,
        % = 4, optional, 32 bits
        ping_slot_period = 0 :: non_neg_integer() | undefined,
        % = 5, optional, 32 bits
        ping_slot_dr = 0 :: non_neg_integer() | undefined,
        % = 6, optional, 32 bits
        ping_slot_freq = 0 :: non_neg_integer() | undefined,
        % = 7, optional
        supports_class_c = false :: boolean() | 0 | 1 | undefined,
        % = 8, optional, 32 bits
        class_c_timeout = 0 :: non_neg_integer() | undefined,
        % = 9, optional
        mac_version = [] :: unicode:chardata() | undefined,
        % = 10, optional
        reg_params_revision = [] :: unicode:chardata() | undefined,
        % = 11, optional, 32 bits
        rx_delay_1 = 0 :: non_neg_integer() | undefined,
        % = 12, optional, 32 bits
        rx_dr_offset_1 = 0 :: non_neg_integer() | undefined,
        % = 13, optional, 32 bits
        rx_datarate_2 = 0 :: non_neg_integer() | undefined,
        % = 14, optional, 32 bits
        rx_freq_2 = 0 :: non_neg_integer() | undefined,
        % = 15, repeated, 32 bits
        factory_preset_freqs = [] :: [non_neg_integer()] | undefined,
        % = 16, optional, 32 bits
        max_eirp = 0 :: non_neg_integer() | undefined,
        % = 17, optional, 32 bits
        max_duty_cycle = 0 :: non_neg_integer() | undefined,
        % = 18, optional
        supports_join = false :: boolean() | 0 | 1 | undefined,
        % = 19, optional
        rf_region = [] :: unicode:chardata() | undefined,
        % = 20, optional
        supports_32bit_f_cnt = false :: boolean() | 0 | 1 | undefined,
        % = 21, optional
        adr_algorithm_id = [] :: unicode:chardata() | undefined}
).
-endif.

-ifndef('NS.ROUTINGPROFILE_PB_H').
-define('NS.ROUTINGPROFILE_PB_H', true).
-record('ns.RoutingProfile',
    % = 1, optional
    {id = <<>> :: iodata() | undefined,
        % = 2, optional
        as_id = [] :: unicode:chardata() | undefined,
        % = 3, optional
        ca_cert = [] :: unicode:chardata() | undefined,
        % = 4, optional
        tls_cert = [] :: unicode:chardata() | undefined,
        % = 5, optional
        tls_key = [] :: unicode:chardata() | undefined}
).
-endif.

-endif.
