-define(PROTOCOL_2, 2).
-define(PUSH_DATA, 0).
-define(PUSH_ACK, 1).
-define(PULL_DATA, 2).
-define(PULL_RESP, 3).
-define(PULL_ACK, 4).
-define(TX_ACK, 5).

%% Value             | Definition
%% :-----------------:|---------------------------------------------------------------------
%%  NONE              | Packet has been programmed for downlink
%%  TOO_LATE          | Rejected because it was already too late to program this packet for downlink
%%  TOO_EARLY         | Rejected because downlink packet timestamp is too much in advance
%%  COLLISION_PACKET  | Rejected because there was already a packet programmed in req timeframe
%%  COLLISION_BEACON  | Rejected because there was already a beacon planned in requested timeframe
%%  TX_FREQ           | Rejected because requested frequency is not supported by TX RF chain
%%  TX_POWER          | Rejected because requested power is not supported by gateway
%%  GPS_UNLOCKED      | Rejected because GPS is unlocked, so GPS timestamp cannot be used

-define(TX_ACK_ERROR_NONE, <<"NONE">>).
-define(TX_ACK_ERROR_TOO_LATE, <<"TOO_LATE">>).
-define(TX_ACK_ERROR_COLLISION_PACKET, <<"COLLISION_PACKET">>).
-define(TX_ACK_ERROR_COLLISION_BEACON, <<"COLLISION_BEACON">>).
-define(TX_ACK_ERROR_TX_FREQ, <<"TX_FREQ">>).
-define(TX_ACK_ERROR_TX_POWER, <<"TX_POWER">>).
-define(TX_ACK_ERROR_GPS_UNLOCKED, <<"GPS_UNLOCKED">>).
