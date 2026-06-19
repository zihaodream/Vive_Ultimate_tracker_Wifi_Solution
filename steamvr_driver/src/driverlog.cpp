//============ Copyright (c) Valve Corporation, All rights reserved. ============
#include "driverlog.h"

#include <stdarg.h>
#include <stdio.h>

static void DriverLogVarArgs( const char *pMsgFormat, va_list args )
{
	char buf[ 1024 ];
#if defined( _WIN32 )
	vsnprintf_s( buf, sizeof( buf ), _TRUNCATE, pMsgFormat, args );
#else
	vsnprintf( buf, sizeof( buf ), pMsgFormat, args );
#endif

	vr::VRDriverLog()->Log( buf );
}


void DriverLog( const char *pMsgFormat, ... )
{
	va_list args;
	va_start( args, pMsgFormat );

	DriverLogVarArgs( pMsgFormat, args );

	va_end( args );
}


void DebugDriverLog( const char *pMsgFormat, ... )
{
#ifdef _DEBUG
	va_list args;
	va_start( args, pMsgFormat );

	DriverLogVarArgs( pMsgFormat, args );

	va_end( args );
#endif
}
