-define(APP, packet_purchaser).
-define(APP_STRING, "packet_purchaser").
-define(UDP_WORKER, pp_udp_worker).

-record(pp_udp_worker_state, {
  location :: no_location | {pos_integer(), float(), float()} | undefined,
  pubkeybin :: libp2p_crypto:pubkey_bin(),
  net_id :: non_neg_integer(),
  socket :: pp_udp_socket:socket(),
  push_data = #{} :: #{binary() => {binary(), reference()}},
  sc_pid :: undefined | pid(),
  pull_resp_fun :: undefined | function(),
  pull_data :: {reference(), binary()} | undefined,
  pull_data_timer :: non_neg_integer(),
  shutdown_timer :: {Timeout :: non_neg_integer(), Timer :: reference()}
}).
