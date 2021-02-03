# NAME

RTP-Proxy-EV - simple rtp proxy

# SYNOPSIS

    # Run RTP-Proxy-EV with the settings in etc/rtc-proxy.conf
    > ./rtp-proxy.pl

# DESCRIPTION

The RTP-Proxy-EV is a simple proxy for RTP traffic and other UDP based media traffic.

Currently the only supported platform is GNU/Linux.

Features
=========

* Media traffic running over either IPv4 or IPv6
* Bridging between IPv4 and IPv6 user agents
* Customizable port range

# DEPENDENCIES

This program requires these other modules and libraries:

EV, YAML::XS, Net::RTP::Packet, Socket6, IO::Socket::INET6 and and others

# AUTHOR

Maxim Motylkov
2014
