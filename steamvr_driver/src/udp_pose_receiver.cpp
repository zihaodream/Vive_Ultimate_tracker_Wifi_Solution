#include "udp_pose_receiver.h"

#include "driverlog.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cerrno>
#include <cstring>
#include <limits>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace
{
#ifdef _WIN32
using SocketHandle = SOCKET;
constexpr SocketHandle kInvalidSocket = INVALID_SOCKET;
void CloseSocket( SocketHandle socket_handle )
{
	if ( socket_handle != INVALID_SOCKET )
		closesocket( socket_handle );
}
#else
using SocketHandle = int;
constexpr SocketHandle kInvalidSocket = -1;
void CloseSocket( SocketHandle socket_handle )
{
	if ( socket_handle >= 0 )
		close( socket_handle );
}
#endif

bool IsNumberChar( char ch )
{
	return std::isdigit( static_cast<unsigned char>( ch ) ) || ch == '-' || ch == '+' || ch == '.' || ch == 'e' || ch == 'E';
}

template <typename T>
bool ReadPod( const char *data, size_t size, size_t *offset, T *value )
{
	if ( !offset || !value || *offset + sizeof( T ) > size )
		return false;
	std::memcpy( value, data + *offset, sizeof( T ) );
	*offset += sizeof( T );
	return true;
}
}

UdpPoseReceiver::~UdpPoseReceiver()
{
	Stop();
}

bool UdpPoseReceiver::Start( const std::string &bind_host, uint16_t port )
{
	if ( running_.exchange( true ) )
		return true;

#ifdef _WIN32
	WSADATA wsa_data{};
	if ( WSAStartup( MAKEWORD( 2, 2 ), &wsa_data ) != 0 )
	{
		running_ = false;
		return false;
	}
#endif

	thread_ = std::thread( &UdpPoseReceiver::ThreadMain, this, bind_host, port );
	return true;
}

void UdpPoseReceiver::Stop()
{
	if ( !running_.exchange( false ) )
		return;

	if ( thread_.joinable() )
		thread_.join();

#ifdef _WIN32
	WSACleanup();
#endif
}

UtkWifiPose UdpPoseReceiver::Latest() const
{
	std::lock_guard<std::mutex> lock( mutex_ );
	return latest_;
}

bool UdpPoseReceiver::IsRunning() const
{
	return running_;
}

uint64_t UdpPoseReceiver::ReceivedCount() const
{
	return received_count_.load();
}

void UdpPoseReceiver::ThreadMain( std::string bind_host, uint16_t port )
{
	SocketHandle socket_handle = socket( AF_INET, SOCK_DGRAM, IPPROTO_UDP );
	if ( socket_handle == kInvalidSocket )
	{
		DriverLog( "utk_wifi_tracker: UDP socket create failed" );
		return;
	}

	sockaddr_in addr{};
	addr.sin_family = AF_INET;
	addr.sin_port = htons( port );
	if ( inet_pton( AF_INET, bind_host.c_str(), &addr.sin_addr ) != 1 )
		addr.sin_addr.s_addr = htonl( INADDR_LOOPBACK );

	if ( bind( socket_handle, reinterpret_cast<sockaddr *>( &addr ), sizeof( addr ) ) != 0 )
	{
		DriverLog( "utk_wifi_tracker: UDP bind failed on %s:%u", bind_host.c_str(), static_cast<unsigned>( port ) );
		CloseSocket( socket_handle );
		return;
	}

#ifdef _WIN32
	DWORD timeout_ms = 100;
	setsockopt( socket_handle, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>( &timeout_ms ), sizeof( timeout_ms ) );
#else
	timeval timeout{};
	timeout.tv_usec = 100000;
	setsockopt( socket_handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof( timeout ) );
#endif

	DriverLog( "utk_wifi_tracker: listening for UDP pose on %s:%u", bind_host.c_str(), static_cast<unsigned>( port ) );

	while ( running_ )
	{
		char buffer[2048];
		sockaddr_in from{};
#ifdef _WIN32
		int from_len = sizeof( from );
		int bytes = recvfrom( socket_handle, buffer, sizeof( buffer ), 0, reinterpret_cast<sockaddr *>( &from ), &from_len );
#else
		socklen_t from_len = sizeof( from );
		int bytes = recvfrom( socket_handle, buffer, sizeof( buffer ), 0, reinterpret_cast<sockaddr *>( &from ), &from_len );
#endif
		if ( bytes <= 0 )
			continue;

		const auto received_at = std::chrono::steady_clock::now();
		UtkWifiPose pose;
		if ( !ParsePosePacket( buffer, static_cast<size_t>( bytes ), &pose ) )
			continue;

		pose.received_at = received_at;
		if ( pose.pc_estimated_pose_time_ns != 0 && pose.source_time_ns != 0 )
		{
			const int64_t offset_ns = static_cast<int64_t>( pose.pc_estimated_pose_time_ns - pose.source_time_ns );
			pose.estimated_pose_at = received_at + std::chrono::nanoseconds( offset_ns );
		}
		const uint64_t count = received_count_.fetch_add( 1 ) + 1;
		{
			std::lock_guard<std::mutex> lock( mutex_ );
			latest_ = pose;
		}
		if ( count == 1 || count % 300 == 0 )
		{
			DriverLog(
				"utk_wifi_tracker: UDP pose #%llu seq=%u status=%d xyz=(%.3f, %.3f, %.3f)",
				static_cast<unsigned long long>( count ),
				static_cast<unsigned>( pose.seq ),
				pose.pose_status,
				pose.x,
				pose.y,
				pose.z );
		}
	}

	CloseSocket( socket_handle );
}

bool UdpPoseReceiver::ParsePosePacket( const char *data, size_t size, UtkWifiPose *pose )
{
	if ( !data || !pose )
		return false;
	if ( size >= 4 && std::memcmp( data, "UTKP", 4 ) == 0 )
		return ParsePoseBinary( data, size, pose );
	return ParsePoseJson( std::string( data, size ), pose );
}

bool UdpPoseReceiver::ParsePoseBinary( const char *data, size_t size, UtkWifiPose *pose )
{
	if ( !data || !pose || size < 86 || std::memcmp( data, "UTKP", 4 ) != 0 )
		return false;

	size_t offset = 4;
	uint8_t version = 0;
	uint8_t seq = 0;
	uint16_t pose_status = 0;
	uint16_t device_time = 0;
	uint64_t source_time_ns = 0;
	uint64_t pc_estimated_pose_time_ns = 0;
	int64_t device_time_ticks = 0;
	float values[13]{};

	if ( !ReadPod( data, size, &offset, &version ) || version != 1 )
		return false;
	if ( !ReadPod( data, size, &offset, &seq ) )
		return false;
	if ( !ReadPod( data, size, &offset, &pose_status ) )
		return false;
	if ( !ReadPod( data, size, &offset, &device_time ) )
		return false;
	if ( !ReadPod( data, size, &offset, &source_time_ns ) )
		return false;
	if ( !ReadPod( data, size, &offset, &pc_estimated_pose_time_ns ) )
		return false;
	if ( !ReadPod( data, size, &offset, &device_time_ticks ) )
		return false;
	for ( float &value : values )
	{
		if ( !ReadPod( data, size, &offset, &value ) )
			return false;
	}

	pose->seq = seq;
	pose->pose_status = static_cast<int>( pose_status );
	pose->device_time = device_time;
	pose->source_time_ns = source_time_ns;
	pose->pc_estimated_pose_time_ns = pc_estimated_pose_time_ns;
	pose->device_time_ticks = device_time_ticks >= 0 ? static_cast<uint64_t>( device_time_ticks ) : 0;
	pose->x = values[0];
	pose->y = values[1];
	pose->z = values[2];
	pose->qx = values[3];
	pose->qy = values[4];
	pose->qz = values[5];
	pose->qw = values[6];
	pose->vx = values[7];
	pose->vy = values[8];
	pose->vz = values[9];
	pose->wx = values[10];
	pose->wy = values[11];
	pose->wz = values[12];
	return true;
}

bool UdpPoseReceiver::ParsePoseJson( const std::string &json, UtkWifiPose *pose )
{
	if ( !pose )
		return false;

	bool ok = true;
	ok = ExtractDoubleNeedle( json, "\"x\":", &pose->x ) && ok;
	ok = ExtractDoubleNeedle( json, "\"y\":", &pose->y ) && ok;
	ok = ExtractDoubleNeedle( json, "\"z\":", &pose->z ) && ok;
	ok = ExtractDoubleNeedle( json, "\"qx\":", &pose->qx ) && ok;
	ok = ExtractDoubleNeedle( json, "\"qy\":", &pose->qy ) && ok;
	ok = ExtractDoubleNeedle( json, "\"qz\":", &pose->qz ) && ok;
	ok = ExtractDoubleNeedle( json, "\"qw\":", &pose->qw ) && ok;
	ExtractDoubleNeedle( json, "\"vx_raw\":", &pose->vx );
	ExtractDoubleNeedle( json, "\"vy_raw\":", &pose->vy );
	ExtractDoubleNeedle( json, "\"vz_raw\":", &pose->vz );
	ExtractDoubleNeedle( json, "\"wx_raw\":", &pose->wx );
	ExtractDoubleNeedle( json, "\"wy_raw\":", &pose->wy );
	ExtractDoubleNeedle( json, "\"wz_raw\":", &pose->wz );
	ExtractIntNeedle( json, "\"pose_status\":", &pose->pose_status );
	int seq = 0;
	if ( ExtractIntNeedle( json, "\"seq\":", &seq ) )
		pose->seq = static_cast<uint8_t>( seq & 0xff );
	ExtractUInt64Needle( json, "\"time_ns\":", &pose->source_time_ns );
	ExtractUInt64Needle( json, "\"pc_estimated_pose_time_ns\":", &pose->pc_estimated_pose_time_ns );
	ExtractUInt64Needle( json, "\"device_time_ticks\":", &pose->device_time_ticks );
	uint64_t device_time = 0;
	if ( ExtractUInt64Needle( json, "\"device_time\":", &device_time ) )
		pose->device_time = static_cast<uint16_t>( device_time & 0xffff );

	return ok;
}

bool UdpPoseReceiver::ExtractDoubleNeedle( const std::string &json, const char *needle, double *value )
{
	size_t pos = json.find( needle );
	if ( pos == std::string::npos )
		return false;
	pos += std::strlen( needle );
	while ( pos < json.size() && std::isspace( static_cast<unsigned char>( json[pos] ) ) )
		++pos;
	const size_t start = pos;
	while ( pos < json.size() && IsNumberChar( json[pos] ) )
		++pos;
	if ( start == pos )
		return false;
	char *end = nullptr;
	const double parsed = std::strtod( json.c_str() + start, &end );
	if ( end == json.c_str() + start )
		return false;
	*value = parsed;
	return true;
}

bool UdpPoseReceiver::ExtractIntNeedle( const std::string &json, const char *needle, int *value )
{
	double parsed = 0.0;
	if ( !ExtractDoubleNeedle( json, needle, &parsed ) )
		return false;
	*value = static_cast<int>( parsed );
	return true;
}

bool UdpPoseReceiver::ExtractUInt64Needle( const std::string &json, const char *needle, uint64_t *value )
{
	size_t pos = json.find( needle );
	if ( pos == std::string::npos )
		return false;
	pos += std::strlen( needle );
	while ( pos < json.size() && std::isspace( static_cast<unsigned char>( json[pos] ) ) )
		++pos;
	const size_t start = pos;
	while ( pos < json.size() && std::isdigit( static_cast<unsigned char>( json[pos] ) ) )
		++pos;
	if ( start == pos )
		return false;
	errno = 0;
	char *end = nullptr;
	const unsigned long long parsed = std::strtoull( json.c_str() + start, &end, 10 );
	if ( errno == ERANGE || end == json.c_str() + start )
		return false;
	static_assert( sizeof( unsigned long long ) >= sizeof( uint64_t ), "unexpected unsigned long long size" );
	*value = static_cast<uint64_t>( parsed );
	return true;
}
