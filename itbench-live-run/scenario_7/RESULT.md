# scenario_7 — ConfigMap/flagd-config paymentFailure=100% (feature-flag, propagates checkout<-payment)
groundtruth: ConfigMap flagd-config; neat 3 ~= obscode 4 TIE (neat had no incident data this run; both went to flagd-config). payment charge.js:37 fails -> checkout gRPC INTERNAL.
