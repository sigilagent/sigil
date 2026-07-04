// Interop shim: vis-network's Network and DataSet are ES6 classes that must be
// constructed with `new`. Jac's cl compiles `Network(...)` to a plain call, so we
// wrap construction in plain-JS factory functions the cl component can call.
import { Network } from "vis-network";
import { DataSet } from "vis-data";

export function makeDataSet(items) {
  return new DataSet(items);
}

export function makeNetwork(el, data, options) {
  return new Network(el, data, options);
}
