# Industream Platform - Simulators & Data Reference

> Deployed via `docker-stack.demo.yml` alongside the main platform stack.
> Adapt hostnames and secrets prefix to your environment (`prod`, `dev`, `staging`).

---

## Infrastructure Overview

| Service | Image | Internal Port | Docker Network |
|---------|-------|---------------|----------------|
| MQTT Broker | `eclipse-mosquitto:2` | 1883 (MQTT), 9001 (WebSocket) | `demo-simulators`, `${ENV}-platform` |
| Industrial Simulator | `python:3.11-slim` | - | `demo-simulators`, `${ENV}-platform` |
| S7 Simulator (PLC) | `fbarresi/softplc:latest-linux` | 102 (S7comm) | `demo-simulators`, `${ENV}-platform` |
| OPC-UA Simulator | `mcr.microsoft.com/iotedge/opc-plc:latest` | 50000 (OPC-UA) | `demo-simulators`, `${ENV}-platform` |
| Modbus Simulator | `oitc/modbus-server:latest` | 5020 (Modbus TCP) | `demo-simulators`, `${ENV}-platform` |
| InfluxDB | `influxdb:${INFLUXDB_VERSION}` | 8086 | `${ENV}-platform` |

> `${ENV}` = `prod`, `dev`, or `staging`. Versions come from `.env` (see `INFLUXDB_VERSION`).

---

## 1. MQTT Broker (Mosquitto)

### Connection

| Parameter | Value |
|-----------|-------|
| Host (internal) | `mqtt-broker` |
| Host (external) | `${INDUSTREAM_SERVER_IP}` (see `.env`) |
| Port MQTT | `1883` |
| Port WebSocket | `9001` |
| Authentication | Anonymous (no auth) |
| Protocol | MQTT v3.1.1 |
| Max message size | 1 MB |
| Persistence | Enabled (`/mosquitto/data/`) |

### Topics

| Topic | Publisher | Interval | Description |
|-------|-----------|----------|-------------|
| `industream/demo/eaf` | Industrial Simulator | 1s | Electric Arc Furnace telemetry |
| `industream/demo/blast_furnace` | Industrial Simulator | 1s | Blast Furnace telemetry |
| `industream/demo/energy` | Industrial Simulator | 1s | Energy Meter telemetry |

---

## 2. Industrial Simulator (MQTT Publisher)

### Connection

| Parameter | Value |
|-----------|-------|
| Image | `python:3.11-slim` |
| Script | `/app/industrial-simulator.py` |
| MQTT Broker | `mqtt-broker:1883` |
| InfluxDB URL | `http://influxdb:8086` |
| InfluxDB Org | `industream` |
| InfluxDB Bucket | `test` |
| InfluxDB Token | Docker secret (`/run/secrets/${ENV}_influx_admin_token`) |
| Simulation Interval | `1s` |
| Timezone | `Europe/Berlin` |

### Equipment Simulated

#### EAF-01 (Electric Arc Furnace)

**MQTT Topic**: `industream/demo/eaf`

**Cycle phases**: `idle` -> `charging` (5 min) -> `melting` (30 min) -> `refining` (15 min) -> `tapping` (10 min) -> `idle`

| Field | Type | Unit | Range | Description |
|-------|------|------|-------|-------------|
| `name` | string | - | `"EAF-01"` | Equipment identifier |
| `timestamp` | string | ISO 8601 | - | UTC timestamp |
| `temperature` | float | C | 20 - 1670 | Bath temperature |
| `power_mw` | float | MW | 4 - 85 | Electrical power draw |
| `electrode_position_mm` | float | mm | 15 - 85 | Electrode position |
| `bath_level_pct` | float | % | 0 - 100 | Steel bath level |
| `oxygen_flow_nm3h` | float | Nm3/h | 80 - 1600 | Oxygen lance flow |
| `carbon_injection_kgmin` | float | kg/min | 0 - 32 | Carbon injection rate |
| `phase` | string | - | idle/charging/melting/refining/tapping | Current process phase |
| `heat_number` | int | - | 1 - N | Current heat (cycle) number |
| `tap_to_tap_min` | float | min | 0 - 60 | Last tap-to-tap duration |
| `energy_kwh_per_ton` | float | kWh/t | 0 - 410 | Specific energy consumption |

**Example MQTT payload**:
```json
{
  "name": "EAF-01",
  "timestamp": "2025-01-15T14:30:00.000000",
  "temperature": 1314.0,
  "power_mw": 76.33,
  "electrode_position_mm": 25.0,
  "bath_level_pct": 100.0,
  "oxygen_flow_nm3h": 1288.0,
  "carbon_injection_kgmin": 25.8,
  "phase": "melting",
  "heat_number": 24,
  "tap_to_tap_min": 60.1,
  "energy_kwh_per_ton": 328.0
}
```

#### BF-01 (Blast Furnace)

**MQTT Topic**: `industream/demo/blast_furnace`

**Tapping cycle**: Every ~120 min, tapping lasts ~20 min

| Field | Type | Unit | Range | Description |
|-------|------|------|-------|-------------|
| `name` | string | - | `"BF-01"` | Equipment identifier |
| `timestamp` | string | ISO 8601 | - | UTC timestamp |
| `hot_blast_temp_c` | float | C | 1090 - 1210 | Hot blast stove temperature |
| `top_gas_temp_c` | float | C | 145 - 215 | Top gas exit temperature |
| `blast_pressure_bar` | float | bar | 3.4 - 4.2 | Blast pressure |
| `blast_volume_nm3min` | float | Nm3/min | 4900 - 6100 | Blast volume |
| `iron_production_th` | float | t/h | 310 - 375 | Iron output rate |
| `coke_rate_kgt` | float | kg/t | 315 - 365 | Coke consumption rate |
| `slag_rate_kgt` | float | kg/t | 230 - 310 | Slag production rate |
| `hearth_temp_c` | float | C | 1425 - 1535 | Hearth temperature |
| `stockline_m` | float | m | 1.9 - 3.1 | Stockline level |
| `co_pct` | float | % | 21.5 - 26.5 | CO content in top gas |
| `co2_pct` | float | % | 19.5 - 24.5 | CO2 content in top gas |
| `tapping_iron` | bool | - | true/false | Iron tapping active |
| `tapping_slag` | bool | - | true/false | Slag tapping active |

**Example MQTT payload**:
```json
{
  "name": "BF-01",
  "timestamp": "2025-01-15T14:30:01.000000",
  "hot_blast_temp_c": 1158.0,
  "top_gas_temp_c": 176.0,
  "blast_pressure_bar": 3.81,
  "blast_volume_nm3min": 5441.0,
  "iron_production_th": 318.6,
  "coke_rate_kgt": 344.0,
  "slag_rate_kgt": 277.0,
  "hearth_temp_c": 1484.0,
  "stockline_m": 2.13,
  "co_pct": 23.7,
  "co2_pct": 22.1,
  "tapping_iron": false,
  "tapping_slag": false
}
```

#### EM-01 (Energy Meter)

**MQTT Topic**: `industream/demo/energy`

**Behavior**: Reacts to EAF power and BF production rate. Power factor drops when EAF > 30 MW.

| Field | Type | Unit | Range | Description |
|-------|------|------|-------|-------------|
| `name` | string | - | `"EM-01"` | Meter identifier |
| `location` | string | - | `"Main_Substation"` | Installation location |
| `timestamp` | string | ISO 8601 | - | UTC timestamp |
| `voltage_l1_v` | float | V | 228 - 232 | Phase L1 voltage |
| `voltage_l2_v` | float | V | 228 - 232 | Phase L2 voltage |
| `voltage_l3_v` | float | V | 228 - 232 | Phase L3 voltage |
| `current_l1_a` | float | A | 30 - 400 | Phase L1 current |
| `current_l2_a` | float | A | 30 - 400 | Phase L2 current |
| `current_l3_a` | float | A | 30 - 400 | Phase L3 current |
| `active_power_kw` | float | kW | 7000 - 90000 | Total active power |
| `reactive_power_kvar` | float | kVAR | 2000 - 60000 | Total reactive power |
| `power_factor` | float | - | 0.83 - 0.97 | Power factor (cos phi) |
| `frequency_hz` | float | Hz | 49.98 - 50.02 | Grid frequency |
| `total_energy_mwh` | float | MWh | 0 - cumulative | Total energy consumed |

**Example MQTT payload**:
```json
{
  "name": "EM-01",
  "location": "Main_Substation",
  "timestamp": "2025-01-15T14:30:04.000000",
  "voltage_l1_v": 229.3,
  "voltage_l2_v": 231.8,
  "voltage_l3_v": 232.0,
  "current_l1_a": 123.2,
  "current_l2_a": 124.3,
  "current_l3_a": 122.0,
  "active_power_kw": 85095.0,
  "reactive_power_kvar": 51195.0,
  "power_factor": 0.857,
  "frequency_hz": 50.01,
  "total_energy_mwh": 1309.94
}
```

---

## 3. S7 Simulator (SoftPLC)

### Connection

| Parameter | Value |
|-----------|-------|
| Image | `fbarresi/softplc:latest-linux` |
| Host (internal) | `s7-simulator` |
| Port | `102` (S7comm / ISO-on-TCP) |
| Rack | `0` |
| Slot | `2` |
| Data directory | `/demodata/` |

### Datablock Configuration

| DB Number | Size | Description |
|-----------|------|-------------|
| DB1 | 2048 bytes | Main demo data block (pre-loaded binary data) |

**S7 Address Format**: `DB1.DBx0.0` where x is the offset

> The S7 simulator (SoftPLC) exposes a single datablock (DB1) with 2048 bytes of pre-loaded demo data. The data is static binary content loaded from `/demodata/datablocks.json`. Custom data mapping depends on the FlowMaker S7 worker configuration.

### FlowMaker Worker

| Parameter | Value |
|-----------|-------|
| Worker | `flow-box-s7-client` (not deployed) |
| Connection string | `s7-simulator:102` |
| Protocol | S7comm (ISO-on-TCP) |

---

## 4. OPC-UA Simulator

### Connection

| Parameter | Value |
|-----------|-------|
| Image | `mcr.microsoft.com/iotedge/opc-plc:latest` |
| Host (internal) | `opcua-simulator` |
| Endpoint URL | `opc.tcp://opcua-simulator:50000` |
| Security | Unsecured transport (`--unsecuretransport`) |
| Auto-accept certs | Yes (`--autoaccept`) |

### Simulator Configuration

| Parameter | Value |
|-----------|-------|
| Update rate | 1000 ms |
| GUID nodes | 5 |
| Fast nodes | 50 |
| Slow nodes | 100 |
| Very fast nodes | 10 (rate: 100 ms) |

### Node Types & Data

| Node Category | Count | Update Rate | Data Type | Description |
|---------------|-------|-------------|-----------|-------------|
| Fast Nodes | 50 | 1s | UInt/Double/Bool | Rapidly changing values |
| Slow Nodes | 100 | 10s | UInt/Double/Bool | Slowly changing values |
| Very Fast Nodes | 10 | 100ms | UInt | High-frequency counters |
| GUID Nodes | 5 | - | Various | Deterministic GUID-identified nodes |
| Special Nodes | ~10 | varies | Various | Built-in simulation patterns |

### Built-in Special Nodes (OPC-PLC standard)

| Node Name | Type | Description |
|-----------|------|-------------|
| `AlternatingBoolean` | Boolean | Toggles true/false periodically |
| `DipData` | Double | Simulates dip pattern |
| `NegativeTrendData` | Double | Decreasing trend |
| `PositiveTrendData` | Double | Increasing trend |
| `RandomSignedInt32` | Int32 | Random signed integer |
| `RandomUnsignedInt32` | UInt32 | Random unsigned integer |
| `SpikeData` | Double | Spike pattern simulation |
| `StepUp` | UInt32 | Incrementing step counter |
| `FastUInt1..50` | UInt32 | Fast-changing unsigned integers |

### FlowMaker Worker

| Parameter | Value |
|-----------|-------|
| Worker | `flow-box-opc-ua-client` (version: see `.env` `FLOWMAKER_BOX_VERSION`) |
| Connection | `opc.tcp://opcua-simulator:50000` |

### InfluxDB Storage

| Parameter | Value |
|-----------|-------|
| Bucket | `opc-ua` |
| Measurement | `demo` |

---

## 5. Modbus TCP Simulator

### Connection

| Parameter | Value |
|-----------|-------|
| Image | `oitc/modbus-server:latest` |
| Host (internal) | `modbus-simulator` |
| Port | `5020` |
| Protocol | Modbus TCP |
| TLS | Disabled |

### Device 1: EAF_Controller (Unit ID: 1)

#### Holding Registers (Read/Write - FC03/FC06)

| Register | Address | Description | Unit |
|----------|---------|-------------|------|
| HR0 | 40001 | EAF Temperature | C |
| HR1 | 40002 | EAF Power | MW |
| HR2 | 40003 | Electrode Position | mm |
| HR3 | 40004 | Bath Level | % |
| HR4 | 40005 | Oxygen Flow | Nm3/h |
| HR5 | 40006 | Carbon Injection Rate | kg/min |
| HR6 | 40007 | Tap-to-Tap Time | min |
| HR7 | 40008 | Heat Number | - |

#### Input Registers (Read-Only - FC04)

| Register | Address | Default | Description | Unit |
|----------|---------|---------|-------------|------|
| IR0 | 30001 | 1650 | Target Temperature | C |
| IR1 | 30002 | 80 | Max Power | MW |
| IR2 | 30003 | 100 | Max Electrode Position | mm |

#### Coils (Read/Write - FC01/FC05)

| Coil | Address | Description |
|------|---------|-------------|
| C0 | 00001 | EAF Running |
| C1 | 00002 | Melting Phase |
| C2 | 00003 | Refining Phase |
| C3 | 00004 | Tapping Phase |
| C4 | 00005 | Alarm Active |

#### Discrete Inputs (Read-Only - FC02)

| Input | Address | Default | Description |
|-------|---------|---------|-------------|
| DI0 | 10001 | true | Power Available |
| DI1 | 10002 | true | Cooling System OK |
| DI2 | 10003 | true | Fume Extraction OK |

### Device 2: BlastFurnace_Controller (Unit ID: 2)

#### Holding Registers (Read/Write - FC03/FC06)

| Register | Address | Description | Unit |
|----------|---------|-------------|------|
| HR0 | 40001 | Hot Blast Temperature | C |
| HR1 | 40002 | Top Gas Temperature | C |
| HR2 | 40003 | Blast Pressure | bar |
| HR3 | 40004 | Blast Volume | Nm3/min |
| HR4 | 40005 | Iron Production Rate | t/h |
| HR5 | 40006 | Coke Rate | kg/t |
| HR6 | 40007 | Slag Rate | kg/t |
| HR7 | 40008 | Hearth Temperature | C |

#### Input Registers (Read-Only - FC04)

| Register | Address | Default | Description | Unit |
|----------|---------|---------|-------------|------|
| IR0 | 30001 | 1200 | Target Hot Blast Temp | C |
| IR1 | 30002 | 4 | Target Blast Pressure | bar |

#### Coils (Read/Write - FC01/FC05)

| Coil | Address | Description |
|------|---------|-------------|
| C0 | 00001 | Furnace Running |
| C1 | 00002 | Tapping Iron |
| C2 | 00003 | Tapping Slag |
| C3 | 00004 | Charging |
| C4 | 00005 | Alarm Active |

#### Discrete Inputs (Read-Only - FC02)

| Input | Address | Default | Description |
|-------|---------|---------|-------------|
| DI0 | 10001 | true | Hot Blast Stoves OK |
| DI1 | 10002 | true | Gas Cleaning OK |
| DI2 | 10003 | true | Cooling System OK |

### Device 3: Energy_Meter (Unit ID: 3)

#### Holding Registers (Read/Write - FC03/FC06)

| Register | Address | Description | Unit |
|----------|---------|-------------|------|
| HR0 | 40001 | Active Power L1 | kW |
| HR1 | 40002 | Active Power L2 | kW |
| HR2 | 40003 | Active Power L3 | kW |
| HR3 | 40004 | Total Active Power | kW |
| HR4 | 40005 | Reactive Power | kVAR |
| HR5 | 40006 | Power Factor | - |
| HR6 | 40007 | Frequency | Hz |
| HR7 | 40008 | Total Energy | MWh |

#### Input Registers (Read-Only - FC04)

| Register | Address | Default | Description | Unit |
|----------|---------|---------|-------------|------|
| IR0 | 30001 | 230 | Nominal Voltage | V |
| IR1 | 30002 | 50 | Nominal Frequency | Hz |

#### Coils (Read/Write - FC01/FC05)

| Coil | Address | Description |
|------|---------|-------------|
| C0 | 00001 | Meter Active |

#### Discrete Inputs (Read-Only - FC02)

| Input | Address | Default | Description |
|-------|---------|---------|-------------|
| DI0 | 10001 | true | Grid Connected |
| DI1 | 10002 | false | Overload Warning |

### FlowMaker Worker

| Parameter | Value |
|-----------|-------|
| Worker | `flow-box-modbus-tcp` (version: see `.env` `FLOWMAKER_BOX_VERSION`) |
| Connection | `modbus-simulator:5020` |

---

## 6. InfluxDB Storage

### Connection

| Parameter | Value |
|-----------|-------|
| Host (internal) | `influxdb:8086` |
| Host (external) | `${INDUSTREAM_SERVER_IP}:8086` (see `.env`) |
| Organization | `industream` |
| Token | Docker secret (`${ENV}_influx_admin_token`) |

### Buckets

| Bucket | Retention | Measurements | Source |
|--------|-----------|--------------|--------|
| `test` | infinite | `electric_arc_furnace`, `blast_furnace`, `energy_meter` | Industrial Simulator (direct write) |
| `steelplant` | infinite | `eaf_computed` | FlowMaker js-expression -> DataBridge |
| `opc-ua` | infinite | `demo` | FlowMaker OPC-UA worker |

### Bucket: `test` - Raw Simulator Data

#### Measurement: `electric_arc_furnace`

**Tags**: `name` (EAF-01), `phase` (idle/charging/melting/refining/tapping)

| Field | Type | Unit |
|-------|------|------|
| `temperature` | float | C |
| `power_mw` | float | MW |
| `electrode_position_mm` | float | mm |
| `bath_level_pct` | float | % |
| `oxygen_flow_nm3h` | float | Nm3/h |
| `carbon_injection_kgmin` | float | kg/min |
| `energy_kwh_per_ton` | float | kWh/t |
| `tap_to_tap_min` | float | min |
| `heat_number` | int | - |

#### Measurement: `blast_furnace`

**Tags**: `name` (BF-01)

| Field | Type | Unit |
|-------|------|------|
| `hot_blast_temp_c` | float | C |
| `top_gas_temp_c` | float | C |
| `blast_pressure_bar` | float | bar |
| `blast_volume_nm3min` | float | Nm3/min |
| `iron_production_th` | float | t/h |
| `coke_rate_kgt` | float | kg/t |
| `slag_rate_kgt` | float | kg/t |
| `hearth_temp_c` | float | C |
| `stockline_m` | float | m |
| `co_pct` | float | % |
| `co2_pct` | float | % |
| `tapping_iron` | boolean | - |
| `tapping_slag` | boolean | - |

#### Measurement: `energy_meter`

**Tags**: `name` (EM-01), `location` (Main_Substation)

| Field | Type | Unit |
|-------|------|------|
| `voltage_l1_v` | float | V |
| `voltage_l2_v` | float | V |
| `voltage_l3_v` | float | V |
| `current_l1_a` | float | A |
| `current_l2_a` | float | A |
| `current_l3_a` | float | A |
| `active_power_kw` | float | kW |
| `reactive_power_kvar` | float | kVAR |
| `power_factor` | float | - |
| `frequency_hz` | float | Hz |
| `total_energy_mwh` | float | MWh |

### Bucket: `steelplant` - Computed KPIs

#### Measurement: `eaf_computed`

**Tags**: none (only system tags)

| Field | Type | Unit |
|-------|------|------|
| `temperature` | float | C |
| `temp_rise_rate_c_per_s` | float | C/s |
| `eta_to_1600c_min` | float | min |
| `power_mw` | float | MW |
| `power_intensity` | float | MW/% |
| `o2_carbon_ratio` | float | - |
| `heat_number` | float | - |
| `phase` | string | - |
| `electrode_deep` | boolean | - |

> Note: `energy_kwh_per_ton` is not yet mapped in the timeseries data sink.

### Bucket: `opc-ua` - OPC-UA Demo Data

#### Measurement: `demo`

| Field | Type | Description |
|-------|------|-------------|
| `AlternatingBoolean` | boolean | Toggling boolean |
| `DipData` | double | Dip pattern |
| `FastUInt1..50` | uint | Fast-changing counters |
| `NegativeTrendData` | double | Decreasing trend |
| `PositiveTrendData` | double | Increasing trend |
| `RandomSignedInt32` | int | Random signed |
| `RandomUnsignedInt32` | uint | Random unsigned |
| `SpikeData` | double | Spike pattern |
| `StepUp` | uint | Incrementing counter |

---

## 7. Grafana Datasources

| Datasource Name | Type | Target |
|-----------------|------|--------|
| `industream-datasource` | Custom plugin | DataBridge API -> InfluxDB (via DataCatalog) |
| `industream raw value` | InfluxDB (Flux) | Direct InfluxDB queries |

### Flux Query Examples

```flux
// EAF raw temperature
from(bucket: "test")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "electric_arc_furnace")
  |> filter(fn: (r) => r._field == "temperature")

// BF all numeric fields
from(bucket: "test")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "blast_furnace")
  |> filter(fn: (r) => r._field =~ /temp|pressure|volume|production|rate/)

// EAF computed KPIs
from(bucket: "steelplant")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "eaf_computed")
  |> filter(fn: (r) => r._field == "temp_rise_rate_c_per_s")

// Energy meter - 3 phase voltages
from(bucket: "test")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "energy_meter")
  |> filter(fn: (r) => r._field =~ /voltage_l[123]_v/)
```

---

## 8. FlowMaker Workers

> Worker versions are configured in `.env` via `FLOWMAKER_BOX_VERSION` (default for all)
> and individual overrides like `FLOWMAKER_BOX_TIMER_VERSION`, `FLOWMAKER_BOX_OPC_UA_CLIENT_VERSION`, etc.
> Check running versions: `docker stack services industream-${ENV} | grep flow-box`

| Worker | Description |
|--------|-------------|
| `flow-box-mqtt-client` | MQTT subscriber/publisher |
| `flow-box-opc-ua-client` | OPC-UA client |
| `flow-box-modbus-tcp` | Modbus TCP client |
| `flow-box-js-expression` | JavaScript computation engine |
| `flow-box-timeseries-workers` | DataBridge read/write |
| `flow-box-influx-client` | Direct InfluxDB client |
| `flow-box-http` | HTTP request client |
| `flow-box-data-logger` | Data logging |
| `flow-box-timer` | Timer/scheduler triggers |
| `flow-box-enqueue` | Queue management |
| `flow-box-postgres-client` | PostgreSQL client |
| `flow-box-notification` | Notification service |
| `flow-box-conditional-dataset-validator` | Data validation |
| `flow-box-equation-solver` | Equation solver |
| `flow-box-test-data-generator` | Test data generation |

---

## 9. Data Pipeline Architecture

```
                                    ┌─────────────────────┐
                                    │  Industrial Simulator│
                                    │  (Python 3.11)       │
                                    └──────┬──────┬────────┘
                                           │      │
                              MQTT (1s)    │      │   Direct write
                                           │      │
                    ┌──────────────────────┼──────┼──────────────────┐
                    │                      │      │                  │
                    ▼                      ▼      ▼                  │
          ┌─────────────┐        ┌────────────────────┐             │
          │ MQTT Broker  │        │     InfluxDB        │             │
          │ (Mosquitto)  │        │  bucket: "test"     │             │
          │ :1883        │        │  :8086              │             │
          └──────┬───────┘        └────────────────────┘             │
                 │                          ▲                        │
                 │ FlowMaker                │                        │
                 │ mqtt-client              │ DataBridge             │
                 ▼                          │ API                    │
          ┌──────────────┐         ┌────────┴───────┐               │
          │ js-expression │────────▶│ timeseries     │               │
          │ (KPI calc)    │         │ data-sink      │               │
          └──────────────┘         └────────────────┘               │
                                           │                        │
                                           ▼                        │
                                   ┌────────────────┐               │
                                   │   InfluxDB      │               │
                                   │ bucket:         │               │
                                   │ "steelplant"    │               │
                                   └────────────────┘               │
                                                                    │
    ┌──────────────┐     ┌──────────────┐     ┌─────────────────┐   │
    │ S7 Simulator  │     │ OPC-UA Sim   │     │ Modbus Sim      │   │
    │ (SoftPLC)     │     │ (Microsoft)  │     │ (oitc)          │   │
    │ :102          │     │ :50000       │     │ :5020           │   │
    └──────────────┘     └──────┬───────┘     └─────────────────┘   │
                                │                                    │
                                │ FlowMaker                         │
                                │ opc-ua-client                     │
                                ▼                                    │
                        ┌────────────────┐                          │
                        │   InfluxDB      │                          │
                        │ bucket: "opc-ua"│                          │
                        └────────────────┘                          │
                                                                    │
                    ┌───────────────────────────────────────────────┘
                    │
                    ▼
            ┌──────────────┐        ┌──────────────┐
            │   Grafana     │◀──────│  DataBridge   │
            │   :3000       │       │  API          │
            └──────────────┘        └──────────────┘
```
