# Instruction cheatsheet

← [Contents](README.md)

The subset you will actually type. `T` stands for `i32 | i64 | f32 | f64` unless
noted. Full listing: the [spec's instruction
index](https://webassembly.github.io/spec/core/appendix/index-instructions.html).

---

## Constants and variables

```wat
i32.const 42        f32.const 1.5        f32.const inf       f32.const nan
i64.const 42        f64.const 1.5        f32.const -0x1.8p+0   ;; hex float

local.get $x        local.set $x         local.tee $x    ;; set and re-push
global.get $g       global.set $g
```

## Integer arithmetic

```wat
i32.add   i32.sub   i32.mul
i32.div_s i32.div_u i32.rem_s i32.rem_u        ;; TRAP on divisor 0
i32.and   i32.or    i32.xor
i32.shl   i32.shr_s i32.shr_u                  ;; shr_s = arithmetic
i32.rotl  i32.rotr
i32.clz   i32.ctz   i32.popcnt
i32.eqz                                        ;; == 0, also logical NOT
```

`i64.*` mirrors all of these.

## Integer comparison → i32 (0 or 1)

```wat
i32.eq  i32.ne
i32.lt_s i32.lt_u  i32.le_s i32.le_u  i32.gt_s i32.gt_u  i32.ge_s i32.ge_u
```

**`_s` for indices and counts, `_u` for addresses and bits.**

## Float arithmetic

```wat
f32.add  f32.sub  f32.mul  f32.div
f32.sqrt f32.abs  f32.neg  f32.copysign
f32.min  f32.max                     ;; NaN-propagating, unlike Math.min
f32.ceil f32.floor f32.trunc f32.nearest   ;; nearest = round-half-to-EVEN
```

## Float comparison → i32

```wat
f32.eq  f32.ne  f32.lt  f32.le  f32.gt  f32.ge     ;; no _s/_u
```

## Conversions

```wat
i32.wrap_i64                  i64.extend_i32_s / _u
i32.trunc_f32_s / _u          ;; TRAPS on NaN or out of range
i32.trunc_sat_f32_s / _u      ;; saturates — prefer this
f32.convert_i32_s / _u        f64.convert_i32_s / _u
f32.demote_f64                f64.promote_f32
i32.reinterpret_f32           f32.reinterpret_i32     ;; free bit-cast
i32.extend8_s  i32.extend16_s
```

## Memory

```wat
i32.load   i32.store          f32.load   f32.store
i64.load   i64.store          f64.load   f64.store

i32.load8_s  i32.load8_u  i32.load16_s  i32.load16_u
i32.store8   i32.store16                        ;; stores just truncate

;; static immediates — offset is FREE, align is a HINT
(f32.load offset=16 align=4 (local.get $base))

memory.size                   ;; → current size in PAGES
memory.grow                   ;; → previous size, or -1. Does NOT trap.
memory.copy  memory.fill      ;; memmove / memset
memory.init $seg   data.drop $seg
```

## Control flow

```wat
(block $out …)                ;; br $out → jumps AFTER the block
(loop  $top …)                ;; br $top → jumps BACK to the start
(if (cond) (then …) (else …))
(if (result T) (cond) (then …) (else …))

(br $label)
(br_if $label (cond))
(br_table $a $b $default (index))
(return)
(return (value))
(unreachable)                 ;; trap
(nop)
(select (a) (b) (cond))       ;; cond ? a : b — branchless, both evaluated
```

## Calls

```wat
(call $fn (arg) (arg))
(call_indirect (type $sig) (args…) (table_index))     ;; index LAST
(return_call $fn (args…))                             ;; tail call, post-MVP
```

## Module fields

```wat
(module
  (import "env" "name" (func $f (param i32) (result f32)))
  (import "env" "mem"  (memory 1))
  (import "env" "g"    (global $g i32))

  (memory (export "memory") 1 16)         ;; initial 1 page, max 16
  (table 4 funcref)
  (elem (i32.const 0) $a $b $c $d)
  (data (i32.const 0) "bytes\00")

  (global $C i32 (i32.const 42))          ;; immutable
  (global $m (mut f32) (f32.const 0.0))   ;; mutable

  (type $sig (func (param f32) (result f32)))

  (func $name (export "name") (param $a i32) (result i32)
    (local $t i32)                        ;; locals FIRST, before any instruction
    (local.get $a))

  (export "alias" (func $name))
  (start $init)
)
```

---

## The loop, memorised as one unit

```wat
(local.set $i (i32.const 0))
(block $done
  (loop $next
    (br_if $done (i32.ge_s (local.get $i) (local.get $count)))
    ;; body
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $next)))
```

## Struct access, memorised as one unit

```wat
(func $addr (param $i i32) (result i32)
  (i32.add (global.get $OFF) (i32.mul (local.get $i) (global.get $STRIDE))))

(local.set $a (call $addr (local.get $i)))
(f32.load offset=0  (local.get $a))     ;; field 0
(f32.load offset=4  (local.get $a))     ;; field 1
```

## Guarded divide, memorised as one unit

```wat
(if (f32.gt (local.get $len) (f32.const 0.001))
  (then (local.set $nx (f32.div (local.get $dx) (local.get $len)))))
```

Skip it and a zero-length vector gives you a NaN that spreads silently through
everything downstream.

---

## Reflexes worth building

| Situation | Reflex |
|---|---|
| Comparing a loop counter | `_s`, not `_u` |
| Converting RNG bits to a float | `convert_i32_u`, not `_s` |
| About to divide | Guard the divisor first |
| Distance test | Compare squares, skip `sqrt` |
| Struct field | `offset=`, not `i32.add` |
| Clearing a region | `memory.fill`, not a byte loop |
| Float→int of a computed value | `trunc_sat`, not `trunc` |
| `memory.grow` | Check for `-1` |
| Rotating a vector 90° | `(-y, x)`. No trig |
| Adding a mutable global | Reset it in `init` too |

---

← [Contents](README.md)
