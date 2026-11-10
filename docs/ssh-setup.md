# SSH setup

Everything in this repo talks to the router over SSH with a key, so you never type the router password into a script.

## 1. Create a key for the router

The SF1200's SSH server (Dropbear) is old and only offers `ssh-rsa`, so use an RSA key:

```bash
ssh-keygen -t rsa -b 4096 -N "" -C "glrouter" -f ~/.ssh/glrouter_rsa
```

## 2. Add host aliases to `~/.ssh/config`

```
Host glrouter
    HostName 192.168.8.1          # your router's LAN address
    User root
    IdentityFile ~/.ssh/glrouter_rsa
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa

# Optional, after installing Tailscale: reach the router from anywhere
Host glrouter-ts
    HostName 100.x.y.z            # the router's Tailscale address
    User root
    IdentityFile ~/.ssh/glrouter_rsa
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
```

## 3. Install the key on the router (asks for the admin password once)

Dropbear reads keys from `/etc/dropbear/authorized_keys`, not `~/.ssh`:

```bash
cat ~/.ssh/glrouter_rsa.pub | ssh glrouter 'cat >> /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys'
```

Check it with `ssh glrouter uname -a`. It should log in without a password.

## Optional: turn off password logins

Once your key works, you can stop SSH from accepting the root password:

```bash
ssh glrouter 'uci set dropbear.@dropbear[0].PasswordAuth=off; uci set dropbear.@dropbear[0].RootPasswordAuth=off; uci commit dropbear; /etc/init.d/dropbear restart'
```

Test a new key login in a second terminal before closing your current one. The web dashboard login isn't affected.

## RouterBar host names

RouterBar uses the `glrouter` and `glrouter-ts` aliases by default. To use different ones:

```bash
defaults write local.routerbar localHost my-router
defaults write local.routerbar tailscaleHost my-router-ts
```
