#ifndef vcl_cmath_h_
#define vcl_cmath_h_

// The -*- C++ -*- math functions header.
// This file is part of the GNU ANSI C++ Library.

#include <vcl/vcl_compiler.h>

// Include system math.h :
#include <math.h>

#ifdef __GNUG__
#pragma interface "vcl_cmath.h"
#endif


// fsm@robots
#if defined (linux) && defined (__OPTIMIZE__)
// * avoid infinite recursion when calling vnl_math::isfinite().
// * avoid symbol in object file being called vnl_math::_isinf.
# undef isinf  
// * avoid that vnl_math::isnan is redefined in <math.h>.
# undef isnan  
#endif


#if !defined(VCL_GCC_295)
// fsm: 2.95 defines these symbols, so defining them here would
// be an error. which architecture does need them?
extern "C++" {
  inline float  abs (float  x) { return fabs (x); }

#if !defined(__hpux__) || defined(__hp9k8__) /* don't know if this is optimal */
  /* hpux and SCO define this in math.h */
  inline double abs (double x) { return fabs (x); }
#endif
  
  inline long double abs (long double x) { return fabs (x); }
  
} // extern "C++"
#endif

#endif
