
Spin up with docker-compose:
`docker-compose up`

You can log into Grafana as `admin:password` and data sources for Loki and Prometheus should be set up as `http://loki:3100` and `http://prometheus:9090`.
This should then allow us to view logs with labels and metrics.

We need to set up a cluster then.
Add the two servers for db2 and db3, you can get the IP address for each like so: 

```
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' db2
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' db3
```