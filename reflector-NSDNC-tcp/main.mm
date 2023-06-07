//
// blocking_tcp_echo_client.cpp
// ~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//
// Copyright (c) 2003-2021 Christopher M. Kohlhoff (chris at kohlhoff dot com)
//
// Distributed under the Boost Software License, Version 1.0. (See accompanying
// file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
//

#import <Foundation/Foundation.h>

#import "IPSME_MsgEnv.h"

#include <cstdlib>
#include <cstring>
#include <sstream>
#include <iostream>
#include <map>
#include <queue>
#include <future>

#include "msg_cache-dedup.h"
#import "JSON_Msg+Ack.h"

NSUUID* g_uuid_ID= [NSUUID UUID];
duplicate g_duplicate;

// https://stackoverflow.com/questions/31755210/how-to-suppress-header-file-warnings-from-an-xcode-project
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "asio.hpp"
#pragma clang diagnostic pop

using asio::ip::tcp;
using namespace std::chrono_literals;

std::mutex g_mtx_disconnect;

//----------------------------------------------------------------------------------------------------------------

typedef std::shared_ptr<tcp::socket> t_ptr_socket;

class session
{
	asio::io_context ioctx_;
	
	tcp::endpoint ep_;
	t_ptr_socket ptr_socket_;

	enum { max_length = 0xffff };
	char msg_[max_length];
	
	std::deque<std::string> q_;
	std::mutex mtx_q_;

public:
	session(tcp::endpoint ep) : ep_(ep) {}
	session(std::string str_address, unsigned short us_port) : ep_(asio::ip::address::from_string(str_address), us_port) {}
	
	void start();
	const tcp::endpoint ep() const { return ep_; }
	const std::string strID() const;

	void do_disconnect();
	void do_reconnect();
	bool is_active() const {
		return (ptr_socket_ != NULL);
	}
	
	void do_read();
	void do_write(std::string str_msg);
	void queue(std::string str) {
		std::lock_guard<std::mutex> guard(mtx_q_);
		q_.push_back(str);
	}
	
	void handler(NSString* nsstr_msg, NSString* object);
};

//----------------------------------------------------------------------------------------------------------------

void session::start()
{
	NSLog(@"main(): Connecting ...");
	
	do_reconnect();
	
	while (true)
	{
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5]];
		
		// https://en.cppreference.com/w/cpp/thread/thread/id
//		std::thread::id this_id = std::this_thread::get_id();
//		std::cout << "... more " << this_id << " sleeping...\n";
		
		ioctx_.run_for(100ms);
	}
}

const std::string session::strID() const
{
	std::stringstream ss_hex;
	
	ss_hex << std::hex << ep_.data();
//	ss_hex << std::hex << ep_.address().to_v4().to_ulong() << ":" << ep_.port();

//	for (const auto &ch : ss_address.str())
//		ss_hex << std::hex << int(ch);
	
	return ss_hex.str();
//	return std::to_string( ptr_socket_->native_handle() );
}

//----------------------------------------------------------------------------------------------------------------

void session::do_disconnect()
{
	std::lock_guard<std::mutex> guard(g_mtx_disconnect);
	
	if (!ptr_socket_->is_open())
		return;
	
	// ptr_socket_old->shutdown(asio::socket_base::shutdown_receive);
	ptr_socket_->close();
	ptr_socket_= NULL;
}

void session::do_reconnect()
{
	t_ptr_socket ptr_socket_1;
	
	std::error_code ec;
	long long t= 1;
	while (true)
	{
		std::cerr << strID() << "::do_reconnect(): Sleeping for " << t-1 << "s \n";

		std::this_thread::sleep_for(std::chrono::seconds(t-1));
		if (t < (1<<5)-1)
			t<<= 1;

		ec.clear();

		tcp::socket socket_1(ioctx_);
		socket_1.connect(ep_, ec);
	
		if (ec)
			continue;
		
		ptr_socket_1= std::make_shared<tcp::socket>(std::move(socket_1));
		break;
	}
	
	assert(ptr_socket_1);

	std::cerr << "do_reconnect(): (Re)connected ... \n";

	{
		std::lock_guard<std::mutex> guard(g_mtx_disconnect);

		assert(!ptr_socket_);
		ptr_socket_= ptr_socket_1;
	}

	{
		std::lock_guard<std::mutex> guard(mtx_q_);

		for (std::string str_msg : q_) {
			NSLog(@"handler_(nsstr): QUEUEd -> asio[%s] -- [%s]", strID().c_str(), str_msg.c_str());
			do_write(str_msg);
		}
	}
	
	do_read();
}

//----------------------------------------------------------------------------------------------------------------
#pragma mark nsdnc <- asio

//TODO? https://www.stroustrup.com/bs_faq2.html#finally

void session::do_read()
{
	// std::cerr << "do_read(): \n";
	
	ptr_socket_->async_read_some(asio::buffer(msg_, max_length), [this](std::error_code ec, std::size_t length)
	{
		if (ec) {
			std::cerr << "async_read_some(): ERROR! " << ec << "\n";
			
			do_disconnect();
			do_reconnect();
			return;
		}
		
		// std::cerr << "async_read_some(): " << msg_ << "\n";
		
		std::string str_msg= std::string(msg_, length);

		if (true == g_duplicate.exists(str_msg)) {
			NSLog(@"async_read_some(): *DUP |<- asio  -- [%s]", str_msg.c_str());
			
			do_read();
			return;
		}
		
		try
		{
			NSString* nsstr_msg= [NSString stringWithCString:str_msg.c_str() encoding:NSUTF8StringEncoding];
		
			NSLog(@"on_message(message_ptr): nsdnc <- asio -- [%@]", nsstr_msg);

			[IPSME_MsgEnv publish:nsstr_msg withObject:g_uuid_ID.UUIDString];
		}
		catch(...) {
			// no matter what happens, at least do_read().
		}
		
		do_read();
	});
}

void session::do_write(std::string str_msg)
{
	std::lock_guard<std::mutex> guard(g_mtx_disconnect);
	
	if ( !is_active() )
		return;
	
	asio::async_write(*ptr_socket_, asio::buffer(str_msg), [this](std::error_code ec, std::size_t /*length*/)
	{
		if (ec) {
			std::cerr << "async_write(): ERROR! " << ec << "\n";

			do_disconnect();
			return;
		}
	});
}

typedef std::shared_ptr<session> t_shptr_session;
typedef std::map<tcp::endpoint,t_shptr_session> t_map_sessions;
t_map_sessions g_map_sessions;

std::mutex g_mtx_sessions;

//----------------------------------------------------------------------------------------------------------------
#pragma mark nsdnc -> asio

tcp::endpoint nsstr_to_endpoint_(NSString* nsstr_address, NSNumber* nsnum_port)
{
	if (nil == nsstr_address || nil == nsnum_port)
		return tcp::endpoint();
	
	std::string str_address= [nsstr_address cStringUsingEncoding:NSUTF8StringEncoding];
	unsigned short us_port= nsnum_port.unsignedShortValue;

	return tcp::endpoint(asio::ip::address::from_string(str_address), us_port);
}

void connect_reflector_server_(NSString* nsstr_address, NSNumber* nsnum_port)
{
	try
	{
		tcp::endpoint ep= nsstr_to_endpoint_(nsstr_address, nsnum_port);
	
		std::lock_guard<std::mutex> guard(g_mtx_sessions);
	
		t_shptr_session shptr_session= g_map_sessions[ep];
		if (!shptr_session)
		{
			t_shptr_session shptr_session_1= std::make_shared<session>(ep);
			
			g_map_sessions[ep]= shptr_session_1;
			std::thread (&session::start, shptr_session_1).detach();
		}
	}
	catch (std::exception ex) {
		NSLog(@"* ERROR: handler_reflector_connect(): Unable to connect with new session: %s", ex.what());
	}
}

bool handler_json_(id id_msg, JSON* json)
{
	NSLog(@"%s: [%@]", __func__, [json toString]);

	// ...
	
	return false;
}

bool handler_NSString_(id id_msg, NSString* nsstr_msg)
{
	NSLog(@"%s: [%@]", __func__, nsstr_msg);
	
	// -----
	
	JSON* json= [JSON parse:nsstr_msg];
	if (json && handler_json_(id_msg, json))
		return true;
	
	// -----
	
	// https://en.cppreference.com/w/cpp/thread/thread/id
	//
	//	std::thread::id this_id = std::this_thread::get_id();
	//	std::cout << "thread " << this_id << ": ";
	
	// TODO: https://github.com/pboettch/json-schema-validator
	
	// accepted: don't reflect, don't continue processing => return true
	// error: continue processing, if none accept as with true, then reflect  => return false;
	// error: don't reflect, don't continue processing (message was ok, but processing failed) => throw e
	//

	std::string str_msg= [nsstr_msg cStringUsingEncoding:NSUTF8StringEncoding];
	g_duplicate.cache(str_msg, t_entry_context(30s));

	std::lock_guard<std::mutex> guard(g_mtx_sessions);

	int i_written= 0;
	for (const auto& [ep, shptr_session] : g_map_sessions)
	{
		// Since this is a reflector, we can reflect messages when individual (delayed) connections become active,
		// instead of waiting for *all* connections to be active before reflecting the message.
		//
		if ( !shptr_session->is_active() )
		{
			NSLog(@"handler_(nsstr): nsdnc -> *QUEUEd | asio[%s] -- [%s]", shptr_session->strID().c_str(), str_msg.c_str());
			shptr_session->queue(str_msg);
			
			continue;
		}

		shptr_session->do_write(str_msg);
		i_written++;
	}

	NSLog(@"handler_(nsstr): nsdnc -> asio[%d/%lu] -- [%@]", i_written, g_map_sessions.size(), nsstr_msg);
	return true;
}

void handler_(id id_msg, NSString* object)
{
	// one way doors are only present when publishing messages out to clients
	//	if ((NULL != object) && (YES == [object isEqualToString:g_uuid_ID.UUIDString]) ) {
	//		NSLog(@"handler_NSString: *DUP |<- nsdnc -- [%@]", nsstr_msg);
	//		return false;
	//	}

	@try {
		if ([id_msg isKindOfClass:[NSString class]] && handler_NSString_(id_msg, id_msg))
			return;
	}
	@catch (id ue) {
		if ([ue isKindOfClass:[NSException class]]) {
			NSException* e= ue;
			NSLog(@"ERR: error is message execution: %@", [e reason]);
		}
		else
			NSLog(@"ERR: error is message execution");
		
		return;
	}
	
	// drop silently ...
	NSLog(@"handler_: DROP! %@", [id_msg class]);
}

//----------------------------------------------------------------------------------------------------------------
#pragma mark main

int main(int argc, char* argv[])
{
	@autoreleasepool
	{
		[IPSME_MsgEnv subscribe:handler_];

		connect_reflector_server_(@"35.187.58.240", [NSNumber numberWithInt:4999]);

		while (true)
		{
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
			
		}
	}

	return 0;
}
