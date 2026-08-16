import { handle } from "./script";
import type { HandleEvent, HandleResult, PluginParamValue } from "derrick";

type HandleFn = typeof handle;
type Arg0<T> = T extends (event: infer E) => unknown ? E : never;
type ParamsOf<E> = E extends HandleEvent<infer P> ? P : never;
type FieldValues<T> = T[keyof T];
type P = ParamsOf<Arg0<HandleFn>>;
type _NoIndex = string extends keyof P ? never : true;
const __noIndex: _NoIndex = true;
type _FieldsAreBase = [FieldValues<P>] extends [PluginParamValue | undefined]
  ? true
  : never;
const __fieldsAreBase: _FieldsAreBase = true;
type _RetOk = ReturnType<HandleFn> extends HandleResult | Promise<HandleResult> ? true : never;
const __retOk: _RetOk = true;
