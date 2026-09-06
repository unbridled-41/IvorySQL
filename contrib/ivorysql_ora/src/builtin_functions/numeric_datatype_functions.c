/*-------------------------------------------------------------------------
 * Copyright 2025 IvorySQL Global Development Team
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * numeric_datatype_functions.c
 *
 * This file contains the implementation of Oracle's
 * numeric data type related built-in functions.
 *
 * Portions Copyright (c) 2023-2026, IvorySQL Global Development Team
 *
 * contrib/ivorysql_ora/src/builtin_functions/numeric_datatype_functions.c
 *
 * add the file for Oracle's built-in data types
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include <math.h>
#include "fmgr.h"
#include "utils/builtins.h"
#include "utils/formatting.h"
#include "utils/numeric.h"

/* Functions implemented in contrib/ivorysql_ora/src/datatype/binary_float.c and contrib/ivorysql_ora/src/datatype/binary_double.c */
extern Datum binary_float_in(PG_FUNCTION_ARGS);
extern Datum binary_double_in(PG_FUNCTION_ARGS);
extern Datum number_binary_float(PG_FUNCTION_ARGS);
extern Datum number_binary_double(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(number_bitand);
PG_FUNCTION_INFO_V1(ora_to_number);
PG_FUNCTION_INFO_V1(number_nanvl);
PG_FUNCTION_INFO_V1(binary_float_nanvl);
PG_FUNCTION_INFO_V1(binary_double_nanvl);
PG_FUNCTION_INFO_V1(ora_to_binary_float);
PG_FUNCTION_INFO_V1(ora_to_binary_double);
PG_FUNCTION_INFO_V1(bit_and_agg_transfn);
PG_FUNCTION_INFO_V1(bit_or_agg_transfn);
PG_FUNCTION_INFO_V1(bit_xor_agg_transfn);
PG_FUNCTION_INFO_V1(bit_and_agg_finalfn);
PG_FUNCTION_INFO_V1(bit_or_agg_finalfn);
PG_FUNCTION_INFO_V1(bit_xor_agg_finalfn);


/*
 * Oracle-compatible BIT_AND_AGG / BIT_OR_AGG / BIT_XOR_AGG aggregates.
 *
 * Oracle operates on the two's-complement representation of the argument,
 * truncating fractional input toward zero.  On Oracle 23ai the accumulator
 * behaves as a 128-bit two's-complement integer: values within the 128-bit
 * range are exact (including negative operands), inputs beyond it wrap, and
 * an aggregate over no non-NULL input yields 0 (not NULL).  NULL inputs are
 * ignored, the return type is always NUMBER, and DISTINCT / window usage
 * follow from the regular PostgreSQL aggregate machinery.
 *
 * The accumulator is kept as an unsigned 128-bit value so that both the
 * digit accumulation of out-of-range inputs and the two's-complement
 * negation wrap naturally.  On platforms without a 128-bit integer type the
 * accumulator degrades to 64 bits.
 */
#ifdef HAVE_INT128
typedef unsigned __int128 ora_uint128;
#else
typedef uint64 ora_uint128;
#endif

typedef struct BitAggState
{
	ora_uint128 bits;			/* two's-complement accumulator */
	bool		have_input;		/* seen at least one non-NULL input */
} BitAggState;

/*
 * Convert a NUMBER to its two's-complement bit pattern.  Fractional values
 * are truncated toward zero (Oracle: BIT_AND_AGG(2.7) = 2, (-2.5) = -2).
 */
static ora_uint128
numeric_two_complement_bits(Numeric num)
{
	char	   *str = DatumGetCString(DirectFunctionCall1(numeric_out,
														   NumericGetDatum(num)));
	const char *s = str;
	bool		neg = false;
	ora_uint128 acc = 0;

	if (*s == '-')
	{
		neg = true;
		s++;
	}
	else if (*s == '+')
		s++;

	/* integer digits only; stops at '.' or the end of the decimal string */
	for (; *s >= '0' && *s <= '9'; s++)
		acc = acc * (ora_uint128) 10 + (ora_uint128) (*s - '0');

	pfree(str);

	/* negation in two's complement wraps modulo 2^(8*sizeof(ora_uint128)) */
	return neg ? (ora_uint128) 0 - acc : acc;
}

/* Convert the accumulator's two's-complement bits back to a NUMBER. */
static Numeric
bits_to_numeric(ora_uint128 bits)
{
	char		buf[64];
	char	   *p = buf + sizeof(buf) - 1;
	bool		neg = ((bits >> (sizeof(ora_uint128) * 8 - 1)) != 0);
	ora_uint128 mag;

	*p = '\0';
	mag = neg ? (ora_uint128) 0 - bits : bits;
	do
	{
		*--p = '0' + (char) (mag % (ora_uint128) 10);
		mag /= (ora_uint128) 10;
	} while (mag != 0);
	if (neg)
		*--p = '-';

	return DatumGetNumeric(DirectFunctionCall3(numeric_in,
											   CStringGetDatum(p),
											   ObjectIdGetDatum(InvalidOid),
											   Int32GetDatum(-1)));
}

static Datum
bit_agg_transfn(PG_FUNCTION_ARGS, ora_uint128 seed, ora_uint128 (*op) (ora_uint128, ora_uint128))
{
	MemoryContext aggcontext;
	BitAggState *state;

	if (!AggCheckCallContext(fcinfo, &aggcontext))
		elog(ERROR, "bit agg transition function called in non-aggregate context");

	if (PG_ARGISNULL(0))
	{
		MemoryContext oldcontext = MemoryContextSwitchTo(aggcontext);

		state = (BitAggState *) palloc(sizeof(BitAggState));
		state->bits = seed;
		state->have_input = false;
		MemoryContextSwitchTo(oldcontext);
	}
	else
		state = (BitAggState *) PG_GETARG_POINTER(0);

	if (!PG_ARGISNULL(1))
	{
		Numeric		num = PG_GETARG_NUMERIC(1);

		state->bits = op(state->bits, numeric_two_complement_bits(num));
		state->have_input = true;
	}

	PG_RETURN_POINTER(state);
}

static ora_uint128
bit_op_and(ora_uint128 a, ora_uint128 b)
{
	return a & b;
}

static ora_uint128
bit_op_or(ora_uint128 a, ora_uint128 b)
{
	return a | b;
}

static ora_uint128
bit_op_xor(ora_uint128 a, ora_uint128 b)
{
	return a ^ b;
}

static Datum
bit_agg_finalfn_int(PG_FUNCTION_ARGS)
{
	BitAggState *state = PG_ARGISNULL(0) ? NULL : (BitAggState *) PG_GETARG_POINTER(0);

	/* Oracle yields 0 (not NULL) when no non-NULL input was aggregated */
	if (state == NULL || !state->have_input)
		return PointerGetDatum(bits_to_numeric(0));

	PG_RETURN_NUMERIC(bits_to_numeric(state->bits));
}

Datum
bit_and_agg_transfn(PG_FUNCTION_ARGS)
{
	return bit_agg_transfn(fcinfo, ~(ora_uint128) 0, bit_op_and);
}

Datum
bit_or_agg_transfn(PG_FUNCTION_ARGS)
{
	return bit_agg_transfn(fcinfo, (ora_uint128) 0, bit_op_or);
}

Datum
bit_xor_agg_transfn(PG_FUNCTION_ARGS)
{
	return bit_agg_transfn(fcinfo, (ora_uint128) 0, bit_op_xor);
}

Datum
bit_and_agg_finalfn(PG_FUNCTION_ARGS)
{
	return bit_agg_finalfn_int(fcinfo);
}

Datum
bit_or_agg_finalfn(PG_FUNCTION_ARGS)
{
	return bit_agg_finalfn_int(fcinfo);
}

Datum
bit_xor_agg_finalfn(PG_FUNCTION_ARGS)
{
	return bit_agg_finalfn_int(fcinfo);
}


Datum
number_bitand(PG_FUNCTION_ARGS)
{
	Numeric		arg1 = PG_GETARG_NUMERIC(0);
	Numeric		arg2 = PG_GETARG_NUMERIC(1);

	PG_RETURN_NUMERIC(numeric_bitand(arg1, arg2));
}

/*
 * ora_to_number
 * converts text to a value of NUMBER data type.
 */
Datum
ora_to_number(PG_FUNCTION_ARGS)
{
	text	   *value = PG_GETARG_TEXT_P(0);
	text	   *fmt = NULL;
	Numeric	result;
	int num = PG_NARGS();

	if(num > 1)
		fmt = PG_GETARG_TEXT_P(1);

	result = ora_to_number_internal(value, fmt);

	if(result == NULL)
		PG_RETURN_NULL();
	else
		PG_RETURN_NUMERIC(result);
}

/*
 * number_nanvl
 * Oracle NANVL(expr1, expr2) for NUMBER: returns expr2 when expr1
 * is NaN, otherwise returns expr1. PostgreSQL's numeric type (unlike
 * Oracle's NUMBER) can hold a NaN value, so this reuses the existing
 * numeric_is_nan() rather than assuming expr1 is never NaN.
 *
 * Oracle only inspects expr1: expr2 is evaluated (and thus only
 * matters) when expr1 is NaN, so this function cannot be STRICT --
 * a NULL expr2 must not force a NULL result when expr1 is a normal
 * (non-NaN) value.
 */
Datum
number_nanvl(PG_FUNCTION_ARGS)
{
	Numeric		arg1;

	if (PG_ARGISNULL(0))
		PG_RETURN_NULL();

	arg1 = PG_GETARG_NUMERIC(0);

	if (!numeric_is_nan(arg1))
		PG_RETURN_NUMERIC(arg1);

	if (PG_ARGISNULL(1))
		PG_RETURN_NULL();

	PG_RETURN_NUMERIC(PG_GETARG_NUMERIC(1));
}

/*
 * binary_float_nanvl
 * Oracle NANVL(expr1, expr2) for BINARY_FLOAT: returns expr2 when
 * expr1 is NaN, otherwise returns expr1. See number_nanvl() for why
 * this cannot be STRICT.
 */
Datum
binary_float_nanvl(PG_FUNCTION_ARGS)
{
	float4		arg1;

	if (PG_ARGISNULL(0))
		PG_RETURN_NULL();

	arg1 = PG_GETARG_FLOAT4(0);

	if (!isnan(arg1))
		PG_RETURN_FLOAT4(arg1);

	if (PG_ARGISNULL(1))
		PG_RETURN_NULL();

	PG_RETURN_FLOAT4(PG_GETARG_FLOAT4(1));
}

/*
 * binary_double_nanvl
 * Oracle NANVL(expr1, expr2) for BINARY_DOUBLE: returns expr2 when
 * expr1 is NaN, otherwise returns expr1. See number_nanvl() for why
 * this cannot be STRICT.
 */
Datum
binary_double_nanvl(PG_FUNCTION_ARGS)
{
	float8		arg1;

	if (PG_ARGISNULL(0))
		PG_RETURN_NULL();

	arg1 = PG_GETARG_FLOAT8(0);

	if (!isnan(arg1))
		PG_RETURN_FLOAT8(arg1);

	if (PG_ARGISNULL(1))
		PG_RETURN_NULL();

	PG_RETURN_FLOAT8(PG_GETARG_FLOAT8(1));
}

/*
 * ora_to_binary_float_internal
 * Convert a character string, with an optional number format model, to a
 * single-precision floating-point value in the same manner as Oracle's
 * TO_BINARY_FLOAT function.
 *
 * When a format model is supplied, the string is first converted to a
 * NUMBER value using the same number format model logic as TO_NUMBER,
 * and then that value is converted to BINARY_FLOAT.  Otherwise the string
 * is parsed directly as a floating-point literal, which also accepts the
 * Oracle special values 'NaN', 'Infinity' (or 'INF') and their negations.
 */
static float4
ora_to_binary_float_internal(text *value, text *fmt, bool *isnull)
{
	Datum		result;

	*isnull = false;

	if (fmt)
	{
		Numeric		num = ora_to_number_internal(value, fmt);

		if (num == NULL)
		{
			*isnull = true;
			return (float4) 0;
		}

		result = DirectFunctionCall1(number_binary_float,
									 NumericGetDatum(num));
	}
	else
	{
		char	   *numstr = text_to_cstring(value);

		result = DirectFunctionCall1(binary_float_in,
									 CStringGetDatum(numstr));
		pfree(numstr);
	}

	return DatumGetFloat4(result);
}

/*
 * ora_to_binary_double_internal
 * Convert a character string, with an optional number format model, to a
 * double-precision floating-point value in the same manner as Oracle's
 * TO_BINARY_DOUBLE function.
 *
 * This is the double-precision counterpart of
 * ora_to_binary_float_internal().
 */
static float8
ora_to_binary_double_internal(text *value, text *fmt, bool *isnull)
{
	Datum		result;

	*isnull = false;

	if (fmt)
	{
		Numeric		num = ora_to_number_internal(value, fmt);

		if (num == NULL)
		{
			*isnull = true;
			return (float8) 0;
		}

		result = DirectFunctionCall1(number_binary_double,
									 NumericGetDatum(num));
	}
	else
	{
		char	   *numstr = text_to_cstring(value);

		result = DirectFunctionCall1(binary_double_in,
									 CStringGetDatum(numstr));
		pfree(numstr);
	}

	return DatumGetFloat8(result);
}

/*
 * ora_to_binary_float
 * Oracle compatible TO_BINARY_FLOAT function.
 *
 * Converts a character string to a value of BINARY_FLOAT data type.
 * The optional second argument is a number format model that describes
 * how the character string should be interpreted.
 */
Datum
ora_to_binary_float(PG_FUNCTION_ARGS)
{
	text	   *value = PG_GETARG_TEXT_P(0);
	text	   *fmt = NULL;
	float4		result;
	bool		isnull;

	if (PG_NARGS() > 1)
		fmt = PG_GETARG_TEXT_P(1);

	result = ora_to_binary_float_internal(value, fmt, &isnull);

	if (isnull)
		PG_RETURN_NULL();

	PG_RETURN_FLOAT4(result);
}

/*
 * ora_to_binary_double
 * Oracle compatible TO_BINARY_DOUBLE function.
 *
 * Converts a character string to a value of BINARY_DOUBLE data type.
 * The optional second argument is a number format model that describes
 * how the character string should be interpreted.
 */
Datum
ora_to_binary_double(PG_FUNCTION_ARGS)
{
	text	   *value = PG_GETARG_TEXT_P(0);
	text	   *fmt = NULL;
	float8		result;
	bool		isnull;

	if (PG_NARGS() > 1)
		fmt = PG_GETARG_TEXT_P(1);

	result = ora_to_binary_double_internal(value, fmt, &isnull);

	if (isnull)
		PG_RETURN_NULL();

	PG_RETURN_FLOAT8(result);
}
