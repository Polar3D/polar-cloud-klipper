# Manual Nginx Configuration Fix

Since you're getting HTML instead of JSON, the nginx configuration needs to be added. 

## Quick Fix Instructions:

1. SSH into your printer:
```bash
ssh mks@your-printer-ip
```

2. Edit the nginx configuration:
```bash
sudo nano /etc/nginx/sites-available/mainsail
```

3. Find the last closing brace `}` in the file (should be at the very end)

4. Add this configuration BEFORE that final `}`:

```nginx
# Polar Cloud nginx configuration snippet

# Redirect /polar-cloud to /polar-cloud/ for user-friendliness
location = /polar-cloud {
    return 301 $scheme://$host/polar-cloud/;
}

location /polar-cloud/ {
    alias /home/mks/polar-cloud/web/;
    try_files $uri $uri/ /polar-cloud/index.html;
}
```

5. Save and exit (Ctrl+X, then Y, then Enter)

6. Test the nginx configuration:
```bash
sudo nginx -t
```

7. If the test passes, reload nginx:
```bash
sudo systemctl reload nginx
```

8. Now try accessing `http://your-printer-ip/polar-cloud/` again

The web interface should now load properly and allow you to enter your Polar Cloud credentials.