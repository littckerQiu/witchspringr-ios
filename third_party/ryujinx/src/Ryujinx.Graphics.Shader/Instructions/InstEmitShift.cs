using Ryujinx.Graphics.Shader.Decoders;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.Translation;

using static Ryujinx.Graphics.Shader.Instructions.InstEmitHelper;
using static Ryujinx.Graphics.Shader.IntermediateRepresentation.OperandHelper;

namespace Ryujinx.Graphics.Shader.Instructions
{
    static partial class InstEmit
    {
        public static void ShfLR(EmitterContext context)
        {
            InstShfLR op = context.GetOp<InstShfLR>();

            Operand srcA = GetSrcReg(context, op.SrcA);
            Operand srcB = GetSrcReg(context, op.SrcB);
            Operand srcC = GetSrcReg(context, op.SrcC);

            EmitShf(context, op.MaxShift, srcA, srcB, srcC, op.Dest, op.M, left: true, op.WriteCC);
        }

        public static void ShfRR(EmitterContext context)
        {
            InstShfRR op = context.GetOp<InstShfRR>();

            Operand srcA = GetSrcReg(context, op.SrcA);
            Operand srcB = GetSrcReg(context, op.SrcB);
            Operand srcC = GetSrcReg(context, op.SrcC);

            EmitShf(context, op.MaxShift, srcA, srcB, srcC, op.Dest, op.M, left: false, op.WriteCC);
        }

        public static void ShfLI(EmitterContext context)
        {
            InstShfLI op = context.GetOp<InstShfLI>();

            Operand srcA = GetSrcReg(context, op.SrcA);
            Operand srcB = Const(op.Imm6);
            Operand srcC = GetSrcReg(context, op.SrcC);

            EmitShf(context, op.MaxShift, srcA, srcB, srcC, op.Dest, op.M, left: true, op.WriteCC);
        }

        public static void ShfRI(EmitterContext context)
        {
            InstShfRI op = context.GetOp<InstShfRI>();

            Operand srcA = GetSrcReg(context, op.SrcA);
            Operand srcB = Const(op.Imm6);
            Operand srcC = GetSrcReg(context, op.SrcC);

            EmitShf(context, op.MaxShift, srcA, srcB, srcC, op.Dest, op.M, left: false, op.WriteCC);
        }

        public static void ShlR(EmitterContext context)
        {
            InstShlR op = context.GetOp<InstShlR>();

            EmitShl(context, GetSrcReg(context, op.SrcA), GetSrcReg(context, op.SrcB), op.Dest, op.M);
        }

        public static void ShlI(EmitterContext context)
        {
            InstShlI op = context.GetOp<InstShlI>();

            EmitShl(context, GetSrcReg(context, op.SrcA), GetSrcImm(context, Imm20ToSInt(op.Imm20)), op.Dest, op.M);
        }

        public static void ShlC(EmitterContext context)
        {
            InstShlC op = context.GetOp<InstShlC>();

            EmitShl(context, GetSrcReg(context, op.SrcA), GetSrcCbuf(context, op.CbufSlot, op.CbufOffset), op.Dest, op.M);
        }

        public static void ShrR(EmitterContext context)
        {
            InstShrR op = context.GetOp<InstShrR>();

            Operand srcA = GetSrcReg(context, op.SrcA);
            Operand srcB = GetSrcReg(context, op.SrcB);

            EmitShr(context, srcA, srcB, op.Dest, op.M, op.Brev, op.Signed);
        }

        public static void ShrI(EmitterContext context)
        {
            InstShrI op = context.GetOp<InstShrI>();

            Operand srcA = GetSrcReg(context, op.SrcA);
            Operand srcB = GetSrcImm(context, Imm20ToSInt(op.Imm20));

            EmitShr(context, srcA, srcB, op.Dest, op.M, op.Brev, op.Signed);
        }

        public static void ShrC(EmitterContext context)
        {
            InstShrC op = context.GetOp<InstShrC>();

            Operand srcA = GetSrcReg(context, op.SrcA);
            Operand srcB = GetSrcCbuf(context, op.CbufSlot, op.CbufOffset);

            EmitShr(context, srcA, srcB, op.Dest, op.M, op.Brev, op.Signed);
        }

        private static void EmitShf(
            EmitterContext context,
            MaxShift maxShift,
            Operand srcA,
            Operand srcB,
            Operand srcC,
            int rd,
            bool mask,
            bool left,
            bool writeCC)
        {
            bool isLongShift = maxShift is MaxShift.U64 or MaxShift.S64;
            bool signedShift = maxShift == MaxShift.S64;
            int maxShiftConst = isLongShift ? 64 : 32;

            // dm patch (instruction vectors of LASRecomp d4c2ff6, MIT; gfx/tests/t_xlate_ops.py): SHF is a funnel shift of C:A (C high), the result
            // the low word of a right shift or the high word of a left shift. .W wraps the shift to the width, otherwise it is clamped to the width
            // (32, or 64 for .U64 / .S64): upstream gave 0 for a clamped shift (a 32-bit SHF.R by 32 or more gives C, SHF.L gives A, SHF.R.S64 by 64
            // gives C's sign) and for a shift of 0 shifted the other word by 32, which SPIR-V and Metal leave undefined (here A | C). Every shift
            // count below is in 0..31
            Operand shift = mask ? context.BitwiseAnd(srcB, Const(maxShiftConst - 1)) : context.IMinimumU32(srcB, Const(maxShiftConst));
            Operand s31 = context.BitwiseAnd(shift, Const(31));
            Operand rest = context.BitwiseAnd(context.ISubtract(Const(32), s31), Const(31));   // 32 - s31 when s31 != 0
            Operand isZero = context.ICompareEqual(s31, Const(0));
            Operand beyondWord = context.ICompareGreaterOrEqualUnsigned(shift, Const(32));

            Operand res;

            if (left)
            {
                // shift < 32: (C << s) | (A >> (32 - s)), C itself for 0; 32 <= shift < 64: A << (shift - 32); 64: 0
                Operand within = context.ConditionalSelect(isZero, srcC, context.BitwiseOr(context.ShiftLeft(srcC, s31), context.ShiftRightU32(srcA, rest)));
                res = context.ConditionalSelect(beyondWord, context.ShiftLeft(srcA, s31), within);

                if (isLongShift)
                {
                    res = context.ConditionalSelect(context.ICompareGreaterOrEqualUnsigned(shift, Const(64)), Const(0), res);
                }
            }
            else
            {
                // shift < 32: (A >> s) | (C << (32 - s)), A itself for 0; 32 <= shift < 64: C >> (shift - 32); 64: 0, or C's sign for .S64
                Operand within = context.ConditionalSelect(isZero, srcA, context.BitwiseOr(context.ShiftRightU32(srcA, s31), context.ShiftLeft(srcC, rest)));
                Operand upper = signedShift ? context.ShiftRightS32(srcC, s31) : context.ShiftRightU32(srcC, s31);
                res = context.ConditionalSelect(beyondWord, upper, within);

                if (isLongShift)
                {
                    Operand full = signedShift ? context.ShiftRightS32(srcC, Const(31)) : Const(0);
                    res = context.ConditionalSelect(context.ICompareGreaterOrEqualUnsigned(shift, Const(64)), full, res);
                }
            }

            context.Copy(GetDest(rd), res);

            if (writeCC)
            {
                InstEmitAluHelper.SetZnFlags(context, res, writeCC);
            }

            // TODO: X.
        }

        private static void EmitShl(EmitterContext context, Operand srcA, Operand srcB, int rd, bool mask)
        {
            if (mask)
            {
                srcB = context.BitwiseAnd(srcB, Const(0x1f));
            }

            Operand res = context.ShiftLeft(srcA, srcB);

            if (!mask)
            {
                // Clamped shift value.
                Operand isLessThan32 = context.ICompareLessUnsigned(srcB, Const(32));

                res = context.ConditionalSelect(isLessThan32, res, Const(0));
            }

            // TODO: X, CC.

            context.Copy(GetDest(rd), res);
        }

        private static void EmitShr(
            EmitterContext context,
            Operand srcA,
            Operand srcB,
            int rd,
            bool mask,
            bool bitReverse,
            bool isSigned)
        {
            if (bitReverse)
            {
                srcA = context.BitfieldReverse(srcA);
            }

            if (mask)
            {
                srcB = context.BitwiseAnd(srcB, Const(0x1f));
            }

            Operand res = isSigned
                ? context.ShiftRightS32(srcA, srcB)
                : context.ShiftRightU32(srcA, srcB);

            if (!mask)
            {
                // Clamped shift value.
                Operand resShiftBy32;

                if (isSigned)
                {
                    resShiftBy32 = context.ShiftRightS32(srcA, Const(31));
                }
                else
                {
                    resShiftBy32 = Const(0);
                }

                Operand isLessThan32 = context.ICompareLessUnsigned(srcB, Const(32));

                res = context.ConditionalSelect(isLessThan32, res, resShiftBy32);
            }

            // TODO: X, CC.

            context.Copy(GetDest(rd), res);
        }
    }
}
