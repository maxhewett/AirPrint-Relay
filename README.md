# AirPrint Relay

![Platform: macOS](https://img.shields.io/badge/platform-macOS-2ea44f)
![AirPrint Clients: iOS and iPadOS](https://img.shields.io/badge/AirPrint_clients-iOS%20%26%20iPadOS-007aff)

AirPrint Relay is a lightweight macOS app that advertises selected local CUPS printer queues as AirPrint-compatible queues for iPhone and iPad.

The app discovers local queues through CUPS tools, advertises its own IPP listener with DNS-SD, captures incoming print jobs, and submits those jobs back into the local CUPS queue.

## Features

- Runs its own IPP-over-HTTP listener on TCP `8631`
- Builds AirPrint TXT records for each selected queue
- Advertises selected queues as `_ipp._tcp,_universal`
- Points iOS clients at AirPrint Relay paths like `/ipp/<queue-name>`
- Captures IPP document payloads and submits them to CUPS with libcups
- Lets you override the AirPrint picker name, location, and model shown for each queue
- Tracks accepted IPP jobs and suppresses duplicate document retries from clients
- Has a log panel with IPP capture, CUPS submission, and Bonjour registration events
- Optionally registers the app as a login item
- Includes a shortcut for easy iOS Safari image printing

## Screenshots
<img width="1072" height="752" alt="image" src="https://github.com/user-attachments/assets/b752b107-f7f7-415c-9611-9fd54106f4a5" />


## Server Setup

On the Mac that owns the printer:

1. Add the printer in System Settings.
2. Make sure the queue accepts jobs.
3. Keep AirPrint Relay reachable from the local network on TCP `8631`.
4. Keep Bonjour/mDNS reachable on UDP `5353`.
5. Keep this app running, or enable `Open at Login`.

For a quick network check from another Mac:

```sh
dns-sd -B _ipp._tcp
nc -vz <mac-hostname-or-ip> 8631
```
