# Helium Packet Purchaser ![CI](https://github.com/helium/packet-purchaser/workflows/CI/badge.svg?branch=master)

The Helium Packet Purchaser is an open source module that is designed to relay Helium packets to a Lorawan Network Server via the Semtech UDP protocol. 

The Packet Purchaser includes state channels and communicates with the Helium Blockchain.

Currently the capabilities of the Packet Purchaser are combined with LNS features in the Helium Console/Router. 

We want to enable other LNS’s to take advantage of the coverage our community has built. To see live coverage go here: https://explorer.helium.com/coverage

## Usage

### Environment Variables

Sample is in `./.env-template`

| Variable                  | Default               | Note                                                                                       |
|---------------------------|-----------------------|--------------------------------------------------------------------------------------------|
| `PP_SC_EXPIRATION_BUFFER` | `5`                   | How closely state channels are allowed to close.                                           |
| `PP_ENABLE_XOR_FILTER`    | `false`               | Enable if you're running an OUI and need to update XOR filters for receiving device joins. |
| `PP_ROUTING_CONFIG_FILE`  | `routing_config.json` | Name of the config file mounted in the docker-compose file.                                |

### Routing Config

Sample is in `./config/routing_config_templates.json`

``` json-with-comments
// Hex numbers are supported as strings prefixed with "0x"
// Required Keys:
//  - net_id
//  - address
//  - port
//
// Optional Keys:
//  - name
//  - multi_buy
//  - joins
[
    {
        "name": "org_name",
        "net_id": "0x000009",
        "address": "www.internet.com",
        "port": 1337,
        "multi_buy": 1,
        "joins": [
            {"app_eui": "0x0000000000000000", "dev_eui": "0x0000000000000000"},
            {"app_eui": 0, "dev_eui": 0},
            // "dev_eui" supports wildcards
            {"app_eui": 1337, "dev_eui": "*"}
        ]
    },
    // optional "multi_buy" defaults to unlimited packets
    {
        "name": "another_org",
        "net_id": 1337,
        "address": "www.internet.com",
        "port": 1111,
        "joins": []
    }
]
```
