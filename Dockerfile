FROM pihole/pihole:latest
RUN curl -sSL https://github.com/town3r/pihole-speedtest/raw/master/mod | sudo bash
