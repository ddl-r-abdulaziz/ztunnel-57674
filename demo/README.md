# Demo: watching the race happen

`run-demo.sh` builds this repo's patched image, stands up a local minikube cluster with ambient-mode Istio pointed at
it, and runs a completely ordinary pod that just retries a connection to the kube API until it succeeds — no pod-side
changes, no sidecar, nothing "ambient-aware" about it. It shows exactly what a real workload sees when it starts up
during the real [istio/istio#57674](https://github.com/istio/istio/issues/57674)
race, deterministically, on demand.

## Prerequisites

`docker`, `minikube`, `istioctl`, and `kubectl` on your `PATH`.

## Run it

```
./run-demo.sh
```

This will:

1. Build `ztunnel-57674/demo:local` from the repo root.
2. Start (or reuse) a minikube profile named `fake-ztunnel-demo`.
3. Load the image into minikube and install Istio's `ambient` profile with
   `ztunnel` pointed at it, configured (via env vars baked into the install) to force identity-wait failures for ~15
   seconds in the
   `fake-ztunnel-demo` namespace.
4. Label that namespace for ambient dataplane mode and run a plain
   `curl`-loop pod in it that hits `https://kubernetes.default.svc/healthz`
   until it gets a response.
5. Print the pod's own logs (its retry attempts and eventual success) next to the matching `fake_race` lines from the
   `ztunnel` logs.

Expect output like this (captured from a real run):

```
----- pod/kube-api-probe (namespace fake-ztunnel-demo) -----
starting kube-api connectivity probe
curl: (6) Could not resolve host: kubernetes.default.svc
attempt 1 failed at 15:02:10
curl: (6) Could not resolve host: kubernetes.default.svc
attempt 2 failed at 15:02:17
succeeded after 2 failed attempt(s), at 15:02:21

----- ztunnel (ztunnel-f8nlz, namespace istio-system) - fake_race entries -----
2026-09-16T15:02:05.122065Z	info	fake_race	fake_race: forcing identity-wait timeout	workload.namespace=fake-ztunnel-demo workload.name=kube-api-probe elapsed_ms=0 window_ms=15000
2026-09-16T15:02:10.123465Z	warn	state	fake_race: forced timeout waiting for workload 'default.fake-ztunnel-demo (kube-api-probe)' from xds
...
```

The pod never crashes or errors out — the failure shows up as a DNS lookup error (`curl` can't resolve
`kubernetes.default.svc` while the window is open, the same as a real timed-out identity wait produces), and it just
retries, same as any real workload would, until the induced window closes.

## Tuning

`HOLD_SECS=<n> ./run-demo.sh` changes how long the forced-failure window stays open (default 15s). Each failed attempt
takes ~5s (the real identity-wait timeout this stands in for) plus a 2s retry pause, so the default gives a handful of
failures before it clears.

## Cleanup

The script deletes the `fake-ztunnel-demo` minikube profile when it's done. Pass `-K` to keep the cluster around (e.g.
to poke around with `kubectl`
afterward); delete it later with:

```
minikube delete --profile fake-ztunnel-demo
```
