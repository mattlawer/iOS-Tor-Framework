//
//  HITorManager.m
//  Tor
//
//  Created by Bazyli Zygan on 23.07.2013.
//  Copyright (c) 2013 Nova Project. All rights reserved.
//

#import "HITorManager.h"
const char tor_git_revision[] =
#ifndef _MSC_VER
#include "micro-revision.i"
#endif
"";
#include "HIMainHack.h"

@interface HITorManager ()

@property (nonatomic, readonly) NSThread *torThread;

- (void)runTor:(NSThread *)obj;

@end

@implementation HITorManager

+ (HITorManager *)defaultManager
{
    static HITorManager *_defaultManager = nil;
    static dispatch_once_t oncePredicate;
    if (!_defaultManager)
        dispatch_once(&oncePredicate, ^{
            _defaultManager = [[self alloc] init];
        });
    
    return _defaultManager;
}

- (void)start
{
    [NSThread detachNewThreadSelector:@selector(runTor:) toTarget:self withObject:nil];
}

- (void)stop
{
    
}


- (void)dealloc
{
    [self stop];
    [super dealloc];
}

- (void)runTor:(NSThread *)obj
{
    // Configure basics
    char *argv[3];
    int argc = 3;
    argv[0] = "torkit";
    argv[1] = "DisableDebuggerAttachment";
    argv[2] = "0";

    
    update_approx_time(time(NULL));
    tor_threads_init();
    init_logging();

    // Main loop here

    if (tor_init(argc, argv)<0)
    {
        [NSThread exit];
        return;
    }
    
    // Local main loop to support NSThread
    int loop_result;
    time_t now;
    
    /* initialize dns resolve map, spawn workers if needed */
    if (dns_init() < 0) {
        if (get_options()->ServerDNSAllowBrokenConfig)
            log_warn(LD_GENERAL, "Couldn't set up any working nameservers. "
                     "Network not up yet?  Will try again soon.");
        else {
            log_err(LD_GENERAL,"Error initializing dns subsystem; exiting.  To "
                    "retry instead, set the ServerDNSAllowBrokenResolvConf option.");
        }
    }
    
#ifdef USE_BUFFEREVENTS
    log_warn(LD_GENERAL, "Tor was compiled with the --enable-bufferevents "
             "option. This is still experimental, and might cause strange "
             "bugs. If you want a more stable Tor, be sure to build without "
             "--enable-bufferevents.");
#endif
    
    handle_signals(1);
    
    /* load the private keys, if we're supposed to have them, and set up the
     * TLS context. */
    if (! client_identity_key_is_set()) {
        if (init_keys() < 0) {
            log_err(LD_BUG,"Error initializing keys; exiting");
            [NSThread exit];
            return;
        }
    }
    
    /* Set up the packed_cell_t memory pool. */
    init_cell_pool();
    
    /* Set up our buckets */
    connection_bucket_init();
#ifndef USE_BUFFEREVENTS
    stats_prev_global_read_bucket = global_read_bucket;
    stats_prev_global_write_bucket = global_write_bucket;
#endif
    
    /* initialize the bootstrap status events to know we're starting up */
    control_event_bootstrap(BOOTSTRAP_STATUS_STARTING, 0);
    
    if (trusted_dirs_reload_certs()) {
        log_warn(LD_DIR,
                 "Couldn't load all cached v3 certificates. Starting anyway.");
    }
    if (router_reload_v2_networkstatus()) {
        [NSThread exit];
        return;
    }
    if (router_reload_consensus_networkstatus()) {
        [NSThread exit];
        return;
    }
    /* load the routers file, or assign the defaults. */
    if (router_reload_router_list()) {
        [NSThread exit];
        return ;
    }
    /* load the networkstatuses. (This launches a download for new routers as
     * appropriate.)
     */
    now = time(NULL);
    directory_info_has_arrived(now, 1);
    
    if (server_mode(get_options())) {
        /* launch cpuworkers. Need to do this *after* we've read the onion key. */
        cpu_init();
    }
    
    /* set up once-a-second callback. */
    if (! second_timer) {
        struct timeval one_second;
        one_second.tv_sec = 1;
        one_second.tv_usec = 0;
        
        second_timer = periodic_timer_new(tor_libevent_get_base(),
                                          &one_second,
                                          second_elapsed_callback,
                                          NULL);
        tor_assert(second_timer);
    }
    
#ifndef USE_BUFFEREVENTS
    if (!refill_timer) {
        struct timeval refill_interval;
        int msecs = get_options()->TokenBucketRefillInterval;
        
        refill_interval.tv_sec =  msecs/1000;
        refill_interval.tv_usec = (msecs%1000)*1000;
        
        refill_timer = periodic_timer_new(tor_libevent_get_base(),
                                          &refill_interval,
                                          refill_callback,
                                          NULL);
        tor_assert(refill_timer);
    }
#endif
    
    while (![[NSThread currentThread] isCancelled])
    {
        
        /* All active linked conns should get their read events activated. */
        SMARTLIST_FOREACH(active_linked_connection_lst, connection_t *, conn,
                          event_active(conn->read_event, EV_READ, 1));
        called_loop_once = smartlist_len(active_linked_connection_lst) ? 1 : 0;
        
        update_approx_time(time(NULL));
        
        /* poll until we have an event, or the second ends, or until we have
         * some active linked connections to trigger events for. */
        loop_result = event_base_loop(tor_libevent_get_base(),
                                      called_loop_once ? EVLOOP_ONCE : 0);
        
        /* let catch() handle things like ^c, and otherwise don't worry about it */
        if (loop_result < 0) {
            int e = tor_socket_errno(-1);
            /* let the program survive things like ^z */
            if (e != EINTR && !ERRNO_IS_EINPROGRESS(e)) {
                log_err(LD_NET,"libevent call with %s failed: %s [%d]",
                        tor_libevent_get_method(), tor_socket_strerror(e), e);
                [NSThread exit];
                return;
            } else if (e == EINVAL) {
                log_warn(LD_NET, "EINVAL from libevent: should you upgrade libevent?");
                if (got_libevent_error())
                {
                    [NSThread exit];
                    return;
                }

            } else {
                if (ERRNO_IS_EINPROGRESS(e))
                    log_warn(LD_BUG,
                             "libevent call returned EINPROGRESS? Please report.");
                log_debug(LD_NET,"libevent call interrupted.");
                /* You can't trust the results of this poll(). Go back to the
                 * top of the big for loop. */
                continue;
            }
        }
    }


    tor_cleanup();
    [NSThread exit];
}

@end
