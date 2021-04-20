%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.17.0

-ifndef(common).
-define(common, true).

-define(common_gpb_version, "4.17.0").

-ifndef('COMMON.KEYENVELOPE_PB_H').
-define('COMMON.KEYENVELOPE_PB_H', true).
-record('common.KeyEnvelope',
    % = 1, optional
    {kek_label = [] :: unicode:chardata() | undefined,
        % = 2, optional
        aes_key = <<>> :: iodata() | undefined}
).
-endif.

-ifndef('COMMON.LOCATION_PB_H').
-define('COMMON.LOCATION_PB_H', true).
-record('common.Location',
    % = 1, optional
    {latitude = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 2, optional
        longitude = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 3, optional
        altitude = 0.0 :: float() | integer() | infinity | '-infinity' | nan | undefined,
        % = 4, optional, enum common.LocationSource
        source = 'UNKNOWN' ::
            'UNKNOWN'
            | 'GPS'
            | 'CONFIG'
            | 'GEO_RESOLVER_TDOA'
            | 'GEO_RESOLVER_RSSI'
            | 'GEO_RESOLVER_GNSS'
            | 'GEO_RESOLVER_WIFI'
            | integer()
            | undefined,
        % = 5, optional, 32 bits
        accuracy = 0 :: non_neg_integer() | undefined}
).
-endif.

-endif.
