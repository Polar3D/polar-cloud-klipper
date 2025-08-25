# Debugging Web Interface Connection Issue

The error "Unexpected token '<'" means the web interface is getting HTML instead of JSON when trying to call the Moonraker API.

## Quick Diagnosis Steps:

1. **Check if Moonraker plugin is loaded**:
```bash
curl -s http://localhost:7125/server/polar_cloud/status
```

If this returns JSON, the plugin is working. If it returns HTML or an error, the plugin isn't loaded.

2. **Check nginx is proxying /server/ correctly**:
```bash
grep -A5 "location /server" /etc/nginx/sites-available/mainsail
```

Should show something like:
```nginx
location /server {
    proxy_pass http://127.0.0.1:7125/server;
    # ... proxy settings
}
```

3. **Test from browser**:
Navigate to: `http://your-printer-ip/server/polar_cloud/status`

This should return JSON, not HTML.

## Common Fixes:

### If Moonraker plugin isn't loaded:
```bash
# Check if the plugin file exists
ls -la /home/mks/moonraker/moonraker/components/polar_cloud.py

# Restart Moonraker to load the plugin
sudo systemctl restart moonraker

# Check Moonraker logs
sudo journalctl -u moonraker -n 50
```

### If nginx isn't proxying correctly:
The mainsail nginx config might be missing the /server proxy. Check if these locations exist:

```bash
sudo nano /etc/nginx/sites-available/mainsail
```

Look for:
- `location /websocket`
- `location /server`
- `location /`

If `/server` is missing, add before the final `}`:
```nginx
location /server {
    proxy_pass http://127.0.0.1:7125/server;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Scheme $scheme;
}
```

Then reload nginx:
```bash
sudo nginx -t && sudo systemctl reload nginx
```