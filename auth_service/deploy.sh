# Auth Service — deploy to Oracle VPS
# Run from the auth_service directory on your local machine:
#
#   scp -r ./* oracle@141.148.32.59:/opt/auth_service/
#   ssh oracle@141.148.32.59 "
#     cd /opt/auth_service &&
#     python3 -m pip install -r requirements.txt &&
#     cp auth.service /etc/systemd/system/ &&
#     systemctl daemon-reload &&
#     systemctl enable auth &&
#     systemctl restart auth
#   "
#
# Then open port 8090:
#   ssh oracle@141.148.32.59 "iptables -I INPUT 1 -p tcp --dport 8090 -j ACCEPT"
