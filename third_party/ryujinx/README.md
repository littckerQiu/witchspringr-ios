# Ryujinx shader translator (vendored subset)

Three projects from Ryujinx 1.3.2: `Ryujinx.Graphics.Shader`, `Ryujinx.Common` and `Spv.Generator`.
The shader translation tool in `gfx/tools/dmsh_xlate` references them to translate the original Switch shaders to SPIR-V.
License: MIT, see `LICENSE.txt`. Upstream: <https://ryujinx.app> (Ryubing; the source is on the project's own Forgejo instance).

Local changes (each marked `dm patch` in the source):
- `CodeGen/Spirv/Instructions.cs` `GenerateTextureSample`: texel offsets read from a register are built with `OpCompositeConstruct` and
  passed as `Offset`, and a four-offset gather becomes four one-offset gathers (from seedds/nxnative 771f62f, MIT). Upstream wrote an
  `OpConstantComposite` of non-constants, invalid SPIR-V on which SPIRV-Cross threw "nullptr" (a compute shader of Tears of the Kingdom's
  `agl_technique_pfx.sharcb`).
- `Translation/Optimizations/Optimizer.cs` `RemoveNode`: cascade into a source's definition only when that definition is
  really unused. Upstream also unlinks a multi-destination operation (a texture sample) when just one of its destinations
  loses its last use, so later copy propagation skips it and deletes definitions it still reads (seen in manosaba's
  TextMeshPro SDF fragment shaders with `UNITY_UI_ALPHACLIP`: the sample coordinates became undefined).
- `Instructions/InstEmitFloatArithmetic.cs` FFMA / FMUL (all forms) with `.FMZ`: a zero factor makes the product 0, also against infinity and NaN
  (D3D9 rules; after tomodachi-native a0aa6c2, MIT). Upstream decoded the field and ignored it (IEEE: NaN).
- `Instructions/InstEmitShift.cs` `EmitShf`: `.W` wraps the shift to the width, otherwise it is clamped to the width (32, or 64 for `.U64` /
  `.S64`), and every emitted shift count stays within 0..31. Upstream gave 0 for a clamped shift (a 32-bit SHF.R by 32 or more gives the high
  word, SHF.L the low word, SHF.R.S64 by 64 the sign) and, for a shift of 0, shifted the other word by 32, which SPIR-V and Metal leave undefined
  (both words ORed on Apple GPUs).
- `Instructions/InstEmitConversion.cs` `EmitI2I`: `.SAT` compares in the source's signedness (upstream: the destination's), and without `.SAT` a
  narrower destination keeps the low bits zero-extended (upstream: all 32 bits).
  The last three are checked on the GPU by `gfx/tests/t_xlate_ops.py` (I2I / SHF vectors from LASRecomp d4c2ff6, MIT).
