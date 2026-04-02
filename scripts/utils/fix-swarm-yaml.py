#!/usr/bin/env python3
"""Fix docker-compose YAML output for Docker Swarm compatibility."""

import sys
import yaml

def fix_networks(networks):
    """Fix networks for Swarm compatibility - set correct name for traefik-public."""
    if isinstance(networks, dict):
        for net_name, net_config in networks.items():
            if isinstance(net_config, dict):
                # Remove 'name' for internal networks
                if not net_config.get('external', False):
                    net_config.pop('name', None)
                # Add name for traefik-public external network
                elif net_name == 'traefik-public':
                    net_config['name'] = 'traefik-shared_traefik-public'
    return networks

def fix_for_swarm(data, is_network_config=False):
    """Recursively fix data structures for Swarm compatibility."""
    if isinstance(data, dict):
        # Remove unsupported top-level properties (but keep 'name' in network configs)
        if not is_network_config:
            data.pop('name', None)

        # Fix networks at top level
        if 'networks' in data and isinstance(data.get('services'), dict):
            # This is the top-level, fix networks
            data['networks'] = fix_networks(data['networks'])

        # Fix deploy.resources.limits/reservations.cpus -> string
        if 'deploy' in data and 'resources' in data['deploy']:
            for key in ['limits', 'reservations']:
                if key in data['deploy']['resources']:
                    res = data['deploy']['resources'][key]
                    if 'cpus' in res and isinstance(res['cpus'], (int, float)):
                        res['cpus'] = str(res['cpus'])

        # Fix ports - ensure published is int
        if 'ports' in data and isinstance(data['ports'], list):
            for port in data['ports']:
                if isinstance(port, dict):
                    if 'published' in port and isinstance(port['published'], str):
                        port['published'] = int(port['published'])
                    if 'target' in port and isinstance(port['target'], str):
                        port['target'] = int(port['target'])

        # Fix devices - convert to list of strings
        if 'devices' in data and isinstance(data['devices'], list):
            new_devices = []
            for device in data['devices']:
                if isinstance(device, dict):
                    # Convert dict format to string format
                    source = device.get('source', '')
                    target = device.get('target', source)
                    new_devices.append(f"{source}:{target}")
                else:
                    new_devices.append(device)
            data['devices'] = new_devices

        # Remove depends_on (not supported in Swarm mode as dict)
        if 'depends_on' in data:
            deps = data['depends_on']
            if isinstance(deps, dict):
                # Convert to simple list
                data['depends_on'] = list(deps.keys())

        # Recurse - mark network configs to preserve 'name'
        for key, value in data.items():
            # Check if we're recursing into the networks dict
            is_net_cfg = (key == 'networks' and isinstance(data.get('services'), dict))
            if is_net_cfg and isinstance(value, dict):
                # Don't recurse into individual network configs
                continue
            data[key] = fix_for_swarm(value)

    elif isinstance(data, list):
        data = [fix_for_swarm(item) for item in data]

    return data

def main():
    if len(sys.argv) != 2:
        print("Usage: fix-swarm-yaml.py <file.yml>", file=sys.stderr)
        sys.exit(1)

    filename = sys.argv[1]

    with open(filename, 'r') as f:
        data = yaml.safe_load(f)

    data = fix_for_swarm(data)

    with open(filename, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    print(f"Fixed {filename} for Swarm compatibility")

if __name__ == '__main__':
    main()
