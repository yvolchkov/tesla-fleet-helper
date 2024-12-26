# Tesla Fleet Helper

Helper scripts to register a third-party application at [developer.tesla.com](https://developer.tesla.com/).

## Requirements

1. **Domain name** bound to Cloudflare DNS.  
2. **Machine with Docker**, running 24/7 (e.g., a Raspberry Pi).

---

## Cloudflare Tunnel Setup

In order to start the registration process for your third-party application, a **public key** must be available at:

https://your-domain/.well-known/appspecific/com.tesla.3p.public-key.pem.

The Docker image provided in this repository **generates** such a key and makes it publicly available using a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/). Therefore, the script will prompt you for the Cloudflare token.

To create a Cloudflare token (if you haven’t already):  
1. Log into [Cloudflare](https://www.cloudflare.com/).  
2. In the left pane, choose **Zero Trust**.  
3. Navigate to **Network** > **Tunnels** > **Create a Tunnel**.  
4. Once created, choose **Public Hostname** > **Add a public hostname**:  
   - **Subdomain**: e.g., `fleet`  
   - **Domain**: e.g., `example.com`  
   - **Service**: `http`  
   - **URL**: `tesla-fleet` (used in your Docker container)

Keep track of the **Tunnel Token** you receive; the script will ask for it.


## Generate Keys and Register Third-Party Application

Run the following command to generate your public key and register a new Tesla application at [developer.tesla.com](https://developer.tesla.com/). The command will prompt for secrets (including the Cloudflare token) and store them in the `secrets` folder:


```bash
mkdir -p tesla-fleet && cd tesla-fleet
my_domain=fleet.example.com
docker run -it --rm \
    --add-host tesla-fleet:127.0.0.1  \
    -v "${PWD}"/secrets:/secrets \
    yvolchkov/tesla-fleet-helper:latest \
    --domain "${my_domain}" \
    --region EMEA
```

[!NOTE] 
Replace fleet.example.com with the domain (or subdomain) you chose in your Cloudflare Tunnel setup.

Regions Supported:
 - **NA_APAC** for North America and Asia-Pacific (excluding China).
 - **EMEA** for Europe, Middle East, and Africa.

This script supports only these two regions due to special requirements for China.

## What the Script Does
1. Generates a **public**/**private** key pair and stores them in the secrets folder.
1. Starts a web server (inside Docker) to serve the public key at https://YOUR_DOMAIN/.well-known/appspecific/com.tesla.3p.public-key.pem.
1. Prompts you to log in to Tesla’s Developer Portal to register a new application.
1. Once you create the application, the script will ask for your **Client ID** and **Client Secret**. Enter these credentials when prompted.

You only need to run this once for initial setup.

#  Setup 24/7 web server serving the public key

The approval process from Tesla can take several weeks. Tesla doesn’t clearly state if the public key must remain accessible throughout the approval period. However, to be safe, keep it up and running:

1. Download the Caddyfile and docker-compose.yaml from this repository:
```bash
curl -O --remote-name-all https://raw.githubusercontent.com/yvolchkov/tesla-fleet-helper/refs/heads/main/{Caddyfile,docker-compose.yaml}
```

2. Start the containers in detached mode:
```bash
docker compose up -d
```

This setup spins up a Caddy web server to serve your public key 24/7 and keeps the Cloudflare tunnel alive.

--- 

Done! You have a publicly accessible public key for your Tesla third-party application. Keep an eye on your inbox for a confirmation email from Tesla indicating your application has been successfully registered. If you run into any issues, check developer.tesla.com or open an issue in this repo.
