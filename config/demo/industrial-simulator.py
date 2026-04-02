#!/usr/bin/env python3
"""
Industrial Data Simulator for Industream Platform Demo
======================================================

Simulates realistic industrial data for:
- Electric Arc Furnace (EAF) - Steel production
- Blast Furnace - Iron production
- Energy consumption monitoring
- Production line metrics

Data is published to MQTT and optionally to InfluxDB.
"""

import os
import time
import json
import math
import random
from datetime import datetime
from dataclasses import dataclass, asdict
from typing import Optional

import paho.mqtt.client as mqtt

# Optional InfluxDB support
try:
    from influxdb_client import InfluxDBClient, Point
    from influxdb_client.client.write_api import SYNCHRONOUS
    INFLUXDB_AVAILABLE = True
except ImportError:
    INFLUXDB_AVAILABLE = False


# Configuration from environment
MQTT_BROKER = os.getenv("MQTT_BROKER", "mqtt-broker")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
SIMULATION_INTERVAL = float(os.getenv("SIMULATION_INTERVAL", "1"))

INFLUXDB_URL = os.getenv("INFLUXDB_URL", "http://influxdb:8086")
INFLUXDB_ORG = os.getenv("INFLUXDB_ORG", "industream")
INFLUXDB_BUCKET = os.getenv("INFLUXDB_BUCKET", "test")

# Read token from Docker secret or environment
TOKEN_FILE = "/run/secrets/prod_influx_admin_token"
if os.path.exists(TOKEN_FILE):
    with open(TOKEN_FILE, "r") as f:
        INFLUXDB_TOKEN = f.read().strip()
else:
    INFLUXDB_TOKEN = os.getenv("INFLUXDB_TOKEN", "")


@dataclass
class ElectricArcFurnace:
    """Electric Arc Furnace (EAF) simulator for steel production."""

    name: str = "EAF-01"
    temperature: float = 25.0  # °C
    power: float = 0.0  # MW
    electrode_position: float = 100.0  # mm
    bath_level: float = 0.0  # %
    oxygen_flow: float = 0.0  # Nm³/h
    carbon_injection: float = 0.0  # kg/min
    phase: str = "idle"  # idle, charging, melting, refining, tapping
    heat_number: int = 1
    tap_to_tap_time: float = 0.0  # minutes
    energy_consumption: float = 0.0  # kWh/t

    # Internal state
    _phase_start: float = 0.0
    _cycle_time: float = 0.0

    def update(self, dt: float):
        """Update EAF state based on current phase."""
        self._cycle_time += dt / 60  # Convert to minutes

        if self.phase == "idle":
            self._transition_to_charging()
        elif self.phase == "charging":
            self._simulate_charging(dt)
        elif self.phase == "melting":
            self._simulate_melting(dt)
        elif self.phase == "refining":
            self._simulate_refining(dt)
        elif self.phase == "tapping":
            self._simulate_tapping(dt)

    def _transition_to_charging(self):
        self.phase = "charging"
        self._phase_start = self._cycle_time
        self.temperature = 25.0 + random.uniform(-5, 5)
        self.bath_level = 0.0

    def _simulate_charging(self, dt: float):
        phase_time = self._cycle_time - self._phase_start
        if phase_time > 5:  # 5 minutes charging
            self.phase = "melting"
            self._phase_start = self._cycle_time
            return

        self.bath_level = min(100, phase_time / 5 * 100)
        self.power = 5 + random.uniform(-1, 1)
        self.temperature = 25 + phase_time * 10 + random.uniform(-5, 5)

    def _simulate_melting(self, dt: float):
        phase_time = self._cycle_time - self._phase_start
        if phase_time > 30:  # 30 minutes melting
            self.phase = "refining"
            self._phase_start = self._cycle_time
            return

        progress = phase_time / 30
        target_temp = 1600 + random.uniform(-20, 20)
        self.temperature = 200 + progress * (target_temp - 200)
        self.temperature += random.uniform(-10, 10)

        # Power profile with variations
        base_power = 60 + 20 * math.sin(progress * math.pi)
        self.power = base_power + random.uniform(-5, 5)

        self.electrode_position = 50 + 30 * math.sin(progress * 2 * math.pi) + random.uniform(-5, 5)
        self.oxygen_flow = 500 + progress * 1000 + random.uniform(-50, 50)
        self.carbon_injection = 10 + progress * 20 + random.uniform(-2, 2)
        self.energy_consumption = progress * 400 + random.uniform(-10, 10)

    def _simulate_refining(self, dt: float):
        phase_time = self._cycle_time - self._phase_start
        if phase_time > 15:  # 15 minutes refining
            self.phase = "tapping"
            self._phase_start = self._cycle_time
            return

        self.temperature = 1650 + random.uniform(-15, 15)
        self.power = 30 + random.uniform(-5, 5)
        self.oxygen_flow = 1500 + random.uniform(-100, 100)
        self.carbon_injection = 5 + random.uniform(-1, 1)

    def _simulate_tapping(self, dt: float):
        phase_time = self._cycle_time - self._phase_start
        if phase_time > 10:  # 10 minutes tapping
            self.tap_to_tap_time = self._cycle_time
            self._cycle_time = 0
            self.heat_number += 1
            self.phase = "idle"
            return

        progress = phase_time / 10
        self.temperature = 1650 - progress * 50 + random.uniform(-10, 10)
        self.bath_level = 100 - progress * 100
        self.power = 5 + random.uniform(-1, 1)
        self.oxygen_flow = 100 + random.uniform(-20, 20)
        self.carbon_injection = 0.0

    def to_mqtt_payload(self) -> dict:
        return {
            "name": self.name,
            "timestamp": datetime.utcnow().isoformat(),
            "temperature": round(self.temperature, 1),
            "power_mw": round(self.power, 2),
            "electrode_position_mm": round(self.electrode_position, 1),
            "bath_level_pct": round(self.bath_level, 1),
            "oxygen_flow_nm3h": round(self.oxygen_flow, 0),
            "carbon_injection_kgmin": round(self.carbon_injection, 1),
            "phase": self.phase,
            "heat_number": self.heat_number,
            "tap_to_tap_min": round(self.tap_to_tap_time, 1),
            "energy_kwh_per_ton": round(self.energy_consumption, 0)
        }


@dataclass
class BlastFurnace:
    """Blast Furnace simulator for iron production."""

    name: str = "BF-01"
    hot_blast_temp: float = 1100.0  # °C
    top_gas_temp: float = 150.0  # °C
    blast_pressure: float = 3.5  # bar
    blast_volume: float = 5000.0  # Nm³/min
    iron_production_rate: float = 300.0  # t/h
    coke_rate: float = 350.0  # kg/t
    slag_rate: float = 280.0  # kg/t
    hearth_temp: float = 1500.0  # °C
    stockline_level: float = 2.5  # m
    co_content: float = 23.0  # %
    co2_content: float = 21.0  # %

    # Tapping state
    tapping_iron: bool = False
    tapping_slag: bool = False
    _tap_timer: float = 0.0

    def update(self, dt: float):
        """Update blast furnace state with realistic variations."""
        # Simulate tapping cycles
        self._tap_timer += dt
        if self._tap_timer > 120:  # Tap every 2 hours (120 minutes in sim)
            self._tap_timer = 0
            self.tapping_iron = True
            self.tapping_slag = random.random() > 0.5
        elif self._tap_timer > 20:  # Tapping lasts 20 minutes
            self.tapping_iron = False
            self.tapping_slag = False

        # Base values with slow drift
        drift = math.sin(time.time() / 600) * 0.05  # 10-minute cycle

        # Hot blast temperature
        self.hot_blast_temp = 1150 + 50 * drift + random.uniform(-10, 10)

        # Top gas temperature
        self.top_gas_temp = 180 + 30 * drift + random.uniform(-5, 5)

        # Blast pressure and volume
        self.blast_pressure = 3.8 + 0.3 * drift + random.uniform(-0.1, 0.1)
        self.blast_volume = 5500 + 500 * drift + random.uniform(-100, 100)

        # Production rate affected by tapping
        base_rate = 320 if not self.tapping_iron else 350
        self.iron_production_rate = base_rate + 20 * drift + random.uniform(-5, 5)

        # Coke and slag rates
        self.coke_rate = 340 + 20 * drift + random.uniform(-5, 5)
        self.slag_rate = 270 + 30 * drift + random.uniform(-10, 10)

        # Hearth temperature
        self.hearth_temp = 1480 + 40 * drift + random.uniform(-15, 15)

        # Stockline level
        self.stockline_level = 2.5 + 0.5 * math.sin(time.time() / 300) + random.uniform(-0.1, 0.1)

        # Gas composition
        self.co_content = 24 + 2 * drift + random.uniform(-0.5, 0.5)
        self.co2_content = 22 - 2 * drift + random.uniform(-0.5, 0.5)

    def to_mqtt_payload(self) -> dict:
        return {
            "name": self.name,
            "timestamp": datetime.utcnow().isoformat(),
            "hot_blast_temp_c": round(self.hot_blast_temp, 0),
            "top_gas_temp_c": round(self.top_gas_temp, 0),
            "blast_pressure_bar": round(self.blast_pressure, 2),
            "blast_volume_nm3min": round(self.blast_volume, 0),
            "iron_production_th": round(self.iron_production_rate, 1),
            "coke_rate_kgt": round(self.coke_rate, 0),
            "slag_rate_kgt": round(self.slag_rate, 0),
            "hearth_temp_c": round(self.hearth_temp, 0),
            "stockline_m": round(self.stockline_level, 2),
            "co_pct": round(self.co_content, 1),
            "co2_pct": round(self.co2_content, 1),
            "tapping_iron": self.tapping_iron,
            "tapping_slag": self.tapping_slag
        }


@dataclass
class EnergyMeter:
    """Energy consumption meter simulator."""

    name: str = "EM-01"
    location: str = "Main_Substation"
    voltage_l1: float = 230.0
    voltage_l2: float = 230.0
    voltage_l3: float = 230.0
    current_l1: float = 0.0
    current_l2: float = 0.0
    current_l3: float = 0.0
    active_power: float = 0.0  # kW
    reactive_power: float = 0.0  # kVAR
    power_factor: float = 0.95
    frequency: float = 50.0  # Hz
    total_energy: float = 0.0  # MWh

    def update(self, dt: float, eaf_power: float = 0, bf_power: float = 0):
        """Update energy meter based on plant load."""
        # Base plant load
        base_load = 5000  # 5 MW base load

        # EAF power (convert MW to kW)
        eaf_load = eaf_power * 1000

        # Estimated BF auxiliaries power
        bf_load = 2000 + bf_power * 10  # Base + variable

        # Total load with random variation
        total_load = base_load + eaf_load + bf_load
        total_load += random.uniform(-total_load * 0.02, total_load * 0.02)

        # Distribute across phases (slight imbalance)
        self.active_power = total_load
        phase_load = total_load / 3
        self.current_l1 = (phase_load / self.voltage_l1) * (1 + random.uniform(-0.02, 0.02))
        self.current_l2 = (phase_load / self.voltage_l2) * (1 + random.uniform(-0.03, 0.02))
        self.current_l3 = (phase_load / self.voltage_l3) * (1 + random.uniform(-0.02, 0.03))

        # Voltage variations
        self.voltage_l1 = 230 + random.uniform(-2, 2)
        self.voltage_l2 = 230 + random.uniform(-2, 2)
        self.voltage_l3 = 230 + random.uniform(-2, 2)

        # Power factor affected by EAF operation
        if eaf_power > 30:
            self.power_factor = 0.85 + random.uniform(-0.02, 0.02)
        else:
            self.power_factor = 0.95 + random.uniform(-0.02, 0.02)

        # Reactive power
        self.reactive_power = self.active_power * math.tan(math.acos(self.power_factor))

        # Frequency (very stable with small variations)
        self.frequency = 50.0 + random.uniform(-0.02, 0.02)

        # Accumulate energy (kWh, convert to MWh)
        self.total_energy += (self.active_power * dt / 3600) / 1000

    def to_mqtt_payload(self) -> dict:
        return {
            "name": self.name,
            "location": self.location,
            "timestamp": datetime.utcnow().isoformat(),
            "voltage_l1_v": round(self.voltage_l1, 1),
            "voltage_l2_v": round(self.voltage_l2, 1),
            "voltage_l3_v": round(self.voltage_l3, 1),
            "current_l1_a": round(self.current_l1, 1),
            "current_l2_a": round(self.current_l2, 1),
            "current_l3_a": round(self.current_l3, 1),
            "active_power_kw": round(self.active_power, 0),
            "reactive_power_kvar": round(self.reactive_power, 0),
            "power_factor": round(self.power_factor, 3),
            "frequency_hz": round(self.frequency, 2),
            "total_energy_mwh": round(self.total_energy, 2)
        }


class IndustrialSimulator:
    """Main simulator orchestrating all industrial processes."""

    def __init__(self):
        self.eaf = ElectricArcFurnace()
        self.blast_furnace = BlastFurnace()
        self.energy_meter = EnergyMeter()

        # MQTT client
        self.mqtt_client = mqtt.Client(client_id="industrial-simulator")
        self.mqtt_connected = False

        # InfluxDB client (optional)
        self.influx_client = None
        self.influx_write_api = None

    def connect_mqtt(self):
        """Connect to MQTT broker."""
        def on_connect(client, userdata, flags, rc):
            if rc == 0:
                self.mqtt_connected = True
                print(f"Connected to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
            else:
                print(f"MQTT connection failed with code {rc}")

        def on_disconnect(client, userdata, rc):
            self.mqtt_connected = False
            print("Disconnected from MQTT broker")

        self.mqtt_client.on_connect = on_connect
        self.mqtt_client.on_disconnect = on_disconnect

        try:
            self.mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            self.mqtt_client.loop_start()
        except Exception as e:
            print(f"Failed to connect to MQTT: {e}")

    def connect_influxdb(self):
        """Connect to InfluxDB (optional)."""
        if not INFLUXDB_AVAILABLE or not INFLUXDB_TOKEN:
            print("InfluxDB not configured, skipping...")
            return

        try:
            self.influx_client = InfluxDBClient(
                url=INFLUXDB_URL,
                token=INFLUXDB_TOKEN,
                org=INFLUXDB_ORG
            )
            self.influx_write_api = self.influx_client.write_api(write_options=SYNCHRONOUS)
            print(f"Connected to InfluxDB at {INFLUXDB_URL}")
        except Exception as e:
            print(f"Failed to connect to InfluxDB: {e}")

    def publish_mqtt(self, topic: str, payload: dict):
        """Publish data to MQTT."""
        if self.mqtt_connected:
            try:
                self.mqtt_client.publish(topic, json.dumps(payload), qos=1)
            except Exception as e:
                print(f"MQTT publish error: {e}")

    def write_influxdb(self, measurement: str, tags: dict, fields: dict):
        """Write data to InfluxDB."""
        if self.influx_write_api:
            try:
                point = Point(measurement)
                for key, value in tags.items():
                    point = point.tag(key, value)
                for key, value in fields.items():
                    if isinstance(value, (int, float)):
                        point = point.field(key, value)
                self.influx_write_api.write(bucket=INFLUXDB_BUCKET, record=point)
            except Exception as e:
                print(f"InfluxDB write error: {e}")

    def run(self):
        """Main simulation loop."""
        print("=" * 60)
        print("Industrial Simulator Starting")
        print("=" * 60)
        print(f"MQTT Broker: {MQTT_BROKER}:{MQTT_PORT}")
        print(f"InfluxDB: {INFLUXDB_URL}")
        print(f"Simulation Interval: {SIMULATION_INTERVAL}s")
        print("=" * 60)

        self.connect_mqtt()
        self.connect_influxdb()

        # Wait for MQTT connection
        time.sleep(2)

        print("Starting simulation...")
        print("Simulating: Electric Arc Furnace, Blast Furnace, Energy Meters")

        while True:
            try:
                # Update all simulators
                self.eaf.update(SIMULATION_INTERVAL)
                self.blast_furnace.update(SIMULATION_INTERVAL)
                self.energy_meter.update(
                    SIMULATION_INTERVAL,
                    self.eaf.power,
                    self.blast_furnace.iron_production_rate
                )

                # Publish to MQTT
                self.publish_mqtt("industream/demo/eaf", self.eaf.to_mqtt_payload())
                self.publish_mqtt("industream/demo/blast_furnace", self.blast_furnace.to_mqtt_payload())
                self.publish_mqtt("industream/demo/energy", self.energy_meter.to_mqtt_payload())

                # Write to InfluxDB
                eaf_data = self.eaf.to_mqtt_payload()
                self.write_influxdb(
                    "electric_arc_furnace",
                    {"name": self.eaf.name, "phase": self.eaf.phase},
                    {k: v for k, v in eaf_data.items() if isinstance(v, (int, float))}
                )

                bf_data = self.blast_furnace.to_mqtt_payload()
                self.write_influxdb(
                    "blast_furnace",
                    {"name": self.blast_furnace.name},
                    {k: v for k, v in bf_data.items() if isinstance(v, (int, float))}
                )

                em_data = self.energy_meter.to_mqtt_payload()
                self.write_influxdb(
                    "energy_meter",
                    {"name": self.energy_meter.name, "location": self.energy_meter.location},
                    {k: v for k, v in em_data.items() if isinstance(v, (int, float))}
                )

                time.sleep(SIMULATION_INTERVAL)

            except KeyboardInterrupt:
                print("\nShutting down simulator...")
                break
            except Exception as e:
                print(f"Simulation error: {e}")
                time.sleep(5)

        # Cleanup
        self.mqtt_client.loop_stop()
        self.mqtt_client.disconnect()
        if self.influx_client:
            self.influx_client.close()


if __name__ == "__main__":
    simulator = IndustrialSimulator()
    simulator.run()
