/*
 * Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
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
 */

#include <mpi.h>
#include <ucp/api/ucp.h>
#include <cstring>
#include <cstdlib>
#include <cassert>
#include <iostream>

#include <rmm/mr/device/default_memory_resource.hpp>

#include "communicator.h"
#include "error.cuh"


void UCXCommunicator::initialize_ucx()
{
    MPI_CALL( MPI_Comm_rank(MPI_COMM_WORLD, &mpi_rank) );
    MPI_CALL( MPI_Comm_size(MPI_COMM_WORLD, &mpi_size) );
    CUDA_RT_CALL( cudaGetDevice(&current_device) );

    ucp_params_t        ucp_params;
    ucp_config_t        *ucp_config;
    ucp_worker_params_t ucp_worker_params;

    memset(&ucp_params, 0, sizeof(ucp_params));
    ucp_params.field_mask        = UCP_PARAM_FIELD_FEATURES | UCP_PARAM_FIELD_ESTIMATED_NUM_EPS;
    ucp_params.features          = UCP_FEATURE_TAG;
    ucp_params.estimated_num_eps = mpi_size;

    UCX_CALL(ucp_config_read(NULL, NULL, &ucp_config));

    UCX_CALL(ucp_init(&ucp_params, ucp_config, &ucp_context));
    ucp_config_release(ucp_config);

    memset(&ucp_worker_params, 0, sizeof(ucp_worker_params));
    ucp_worker_params.field_mask  = UCP_WORKER_PARAM_FIELD_THREAD_MODE;
    ucp_worker_params.thread_mode = UCS_THREAD_MODE_SINGLE;  // only the master thread can access UCX

    UCX_CALL(ucp_worker_create(ucp_context, &ucp_worker_params, &ucp_worker));

    UCX_CALL(ucp_worker_get_address(ucp_worker, &ucp_worker_address, &ucp_worker_address_len));
}


void UCXCommunicator::create_endpoints()
{
    /* Broadcast worker addresses to all nodes */

    void *ucp_worker_address_book = malloc(ucp_worker_address_len * mpi_size);
    MPI_CALL(MPI_Allgather(
        ucp_worker_address, ucp_worker_address_len, MPI_CHAR,
        ucp_worker_address_book, ucp_worker_address_len, MPI_CHAR, MPI_COMM_WORLD
    ));

    /* Create endpoints of all nodes */

    std::vector<ucp_ep_params_t> ucp_ep_params;

    ucp_endpoints.resize(mpi_size);
    ucp_ep_params.resize(mpi_size);

    for (int irank = 0; irank < mpi_size; irank++) {
        memset(&ucp_ep_params[irank], 0, sizeof(ucp_ep_params));
        ucp_ep_params[irank].field_mask = UCP_EP_PARAM_FIELD_REMOTE_ADDRESS;
        ucp_ep_params[irank].address = (ucp_address_t *)(
            (char *)ucp_worker_address_book + irank * ucp_worker_address_len
        );

        UCX_CALL(ucp_ep_create(ucp_worker, &ucp_ep_params[irank], &ucp_endpoints[irank]));
    }

    free(ucp_worker_address_book);
}


void UCXCommunicator::initialize()
{
    initialize_ucx();
    create_endpoints();
}


void empty_callback_func() {}


comm_handle_t UCXCommunicator::send(const void *buf, int64_t count, int element_size, int dest, int tag)
{
    // TODO: the design of the communication tag should be in line with the design of UCXBufferCommunicator
    ucs_status_ptr_t req = ucp_tag_send_nb(
        ucp_endpoints[dest], buf, count, ucp_dt_make_contig(element_size),
        tag * mpi_size + mpi_rank, (ucp_send_callback_t) empty_callback_func
    );

    CHECK_ERROR(UCS_PTR_IS_ERR(req), false, "ucp_tag_send_nb");

    if (UCS_PTR_STATUS(req) == UCS_OK) {
        // already locally completed
        return nullptr;
    } else {
        return req;
    }
}


comm_handle_t UCXCommunicator::recv(void *buf, int64_t count, int element_size, int source, int tag)
{
    // TODO: the design of the communication tag should be in line with the design of UCXBufferCommunicator
    ucs_status_ptr_t req = ucp_tag_recv_nb(
        ucp_worker, buf, count, ucp_dt_make_contig(element_size),
        tag * mpi_size + source, (ucp_tag_t)-1, (ucp_tag_recv_callback_t) empty_callback_func
    );

    CHECK_ERROR(UCS_PTR_IS_ERR(req), false, "ucp_tag_msg_recv_nb");

    return req;
}


comm_handle_t UCXCommunicator::recv(void **buf, int64_t *count, int element_size, int source, int tag)
{
    ucp_tag_message_h ucp_tag_message;
    ucp_tag_recv_info_t ucp_probe_info;

    /* Probe the size of the incoming message */

    while (true) {
        ucp_tag_message = ucp_tag_probe_nb(ucp_worker, tag * mpi_size + source, (ucp_tag_t) -1, 1, &ucp_probe_info);

        if (ucp_tag_message != NULL) {
            // the message has already arrived
            break;
        }

        ucp_worker_progress(ucp_worker);
    }

    /* Allocate receive buffer */

    *buf = rmm::mr::get_default_resource()->allocate(ucp_probe_info.length, 0);

    /* Received data */

    ucs_status_ptr_t req = ucp_tag_msg_recv_nb(
        ucp_worker, *buf, ucp_probe_info.length / element_size,
        ucp_dt_make_contig(element_size), ucp_tag_message, (ucp_tag_recv_callback_t) empty_callback_func
    );

    CHECK_ERROR(UCS_PTR_IS_ERR(req), false, "ucp_tag_msg_recv_nb");

    if (count != nullptr)
        *count = ucp_probe_info.length / element_size;

    return req;
}


void UCXCommunicator::wait(comm_handle_t request)
{
    while (ucp_request_check_status(request) == UCS_INPROGRESS) {
        ucp_worker_progress(ucp_worker);
    }

    ucp_request_free(request);
}


void UCXCommunicator::waitall(std::vector<comm_handle_t> requests)
{
    UCXCommunicator::waitall(requests.begin(), requests.end());
}


void UCXCommunicator::waitall(
                              std::vector<comm_handle_t>::const_iterator begin,
                              std::vector<comm_handle_t>::const_iterator end)
{
    while (true) {
        bool all_finished = true;

        for (auto it = begin; it != end; it++) {
            auto & request = *it;
            if (request != nullptr && ucp_request_check_status(request) == UCS_INPROGRESS) {
                all_finished = false;
                break;
            }
        }

        if (all_finished)
            break;

        ucp_worker_progress(ucp_worker);
    }

    for (auto it = begin; it != end; it++) {
        auto & request = *it;
        if (request != nullptr)
            ucp_request_free(request);
    }
}


void UCXCommunicator::finalize()
{
    std::vector<comm_handle_t> close_nb_reqs(mpi_size, nullptr);

    for (int irank = 0; irank < mpi_size; irank++) {
        ucs_status_ptr_t ucs_status_ptr = ucp_ep_close_nb(ucp_endpoints[irank], UCP_EP_CLOSE_MODE_FLUSH);

        CHECK_ERROR(UCS_PTR_IS_ERR(ucs_status_ptr), false, "ucp_ep_close_nb");

        if (UCS_PTR_STATUS(ucs_status_ptr) != UCS_OK)
            close_nb_reqs[irank] = ucs_status_ptr;
    }

    UCXCommunicator::waitall(close_nb_reqs);

    // Barrier is necessary here because we do not want to destroy any worker before all ranks have closed the
    // endpoints.
    MPI_Barrier(MPI_COMM_WORLD);

    ucp_worker_release_address(ucp_worker, ucp_worker_address);
    ucp_worker_destroy(ucp_worker);
    ucp_cleanup(ucp_context);

    MPI_CALL(MPI_Finalize());
}


static void request_init(void *request)
{
    UCXBufferCommunicator::CommInfo *info = (UCXBufferCommunicator::CommInfo *) request;
    info->completed = false;
    info->comm = nullptr;
    info->orig_info = nullptr;
    info->custom_allocated = false;
}


void UCXBufferCommunicator::initialize_ucx()
{
    // Note: This initialization is different from UCXCommunicator on requesting reserved space in the communication
    // handle.

    MPI_CALL( MPI_Comm_rank(MPI_COMM_WORLD, &mpi_rank) );
    MPI_CALL( MPI_Comm_size(MPI_COMM_WORLD, &mpi_size) );
    CUDA_RT_CALL( cudaGetDevice(&current_device) );

    ucp_params_t        ucp_params;
    ucp_config_t        *ucp_config;
    ucp_worker_params_t ucp_worker_params;

    assert(sizeof(SendInfo) == sizeof(RecvInfo));

    memset(&ucp_params, 0, sizeof(ucp_params));
    ucp_params.field_mask        = UCP_PARAM_FIELD_FEATURES |
                                   UCP_PARAM_FIELD_ESTIMATED_NUM_EPS |
                                   UCP_PARAM_FIELD_REQUEST_INIT |
                                   UCP_PARAM_FIELD_REQUEST_SIZE;

    ucp_params.features          = UCP_FEATURE_TAG;
    ucp_params.estimated_num_eps = mpi_size;
    ucp_params.request_size      = sizeof(SendInfo);
    ucp_params.request_init      = request_init;

    UCX_CALL(ucp_config_read(NULL, NULL, &ucp_config));

    UCX_CALL(ucp_init(&ucp_params, ucp_config, &ucp_context));
    ucp_config_release(ucp_config);

    memset(&ucp_worker_params, 0, sizeof(ucp_worker_params));
    ucp_worker_params.field_mask  = UCP_WORKER_PARAM_FIELD_THREAD_MODE;
    ucp_worker_params.thread_mode = UCS_THREAD_MODE_SINGLE;  // only the master thread can access UCX

    UCX_CALL(ucp_worker_create(ucp_context, &ucp_worker_params, &ucp_worker));

    UCX_CALL(ucp_worker_get_address(ucp_worker, &ucp_worker_address, &ucp_worker_address_len));
}


void UCXBufferCommunicator::initialize()
{
    UCXCommunicator::initialize();

    if (mpi_size > 65536) {
        throw "Ranks > 65536 is not supported due to tag limitation.";
    }

    /* Create priority stream for copying between user buffer and comm buffer. Useful for overlapping. */

    int least_priority;
    int greatest_priority;

    CUDA_RT_CALL( cudaDeviceGetStreamPriorityRange(&least_priority, &greatest_priority) );

    CUDA_RT_CALL( cudaStreamCreateWithPriority(&copy_stream, cudaStreamNonBlocking, greatest_priority) );
}


void UCXBufferCommunicator::setup_cache(int64_t ncaches, int64_t buffer_size)
{
    comm_buffer_size = buffer_size;
    cache_start_addr = rmm::mr::get_default_resource()->allocate(comm_buffer_size * ncaches, 0);

    for (int icache = 0; icache < ncaches; icache ++) {
        void *current_buffer = (void *)((char *)cache_start_addr + icache * buffer_size);
        buffer_cache.push(current_buffer);
    }
}


void UCXBufferCommunicator::warmup_cache()
{
    if (mpi_size == 1)
        return;

    int ncaches = buffer_cache.size();
    int partner = mpi_size - mpi_rank - 1;

    if (partner == mpi_rank)
        partner = 0;

    comm_handle_t request;

    /* Register the communication buffer by sending it to a remote rank.*/

    if (mpi_rank < mpi_size / 2) {
        request = UCXCommunicator::send(cache_start_addr, ncaches * comm_buffer_size, 1, partner, 10);
    } else {
        request = UCXCommunicator::recv(cache_start_addr, ncaches * comm_buffer_size, 1, partner, 10);
    }

    UCXCommunicator::wait(request);

    if (mpi_rank == 0 && mpi_size % 2) {
        request = UCXCommunicator::send(cache_start_addr, ncaches * comm_buffer_size, 1, mpi_size / 2, 10);
        UCXCommunicator::wait(request);
    }
}

/**
 * Get the communication tag passed to UCX from user defined tag and source rank.
 *
 * This function is necessary because UCX receive API does not specify a source.
 * Therefore, the current implementation uses tag matching to differentiate messages
 * coming from different ranks.
 *
 * @param[in] user_tag      User-specified tag
 * @param[in] source_rank   Rank number of the sender of this message
 *
 * @returns                 Communication tag passed to UCX
 */
uint64_t get_comm_tag(int user_tag, int source_rank)
{
    uint64_t comm_tag = 0LLU;
    // user_tag occupies the most significant 32 bits of comm_tag
    comm_tag |= ((uint64_t)user_tag << 32);
    // source rank occupies the least significant 32 bits of comm_tag
    comm_tag |= (uint64_t)source_rank;

    return comm_tag;
}


static void send_handler(void *request, ucs_status_t status)
{
    UCXBufferCommunicator::SendInfo *info = (UCXBufferCommunicator::SendInfo *)request;
    int element_size = info->element_size;
    int ibatch = info->ibatch;

    const int64_t nelements_per_batch = info->comm->comm_buffer_size / element_size;

    int64_t nelements_remaining = *(info->count) - nelements_per_batch * ibatch;

    request = nullptr;

    while (nelements_remaining > 0) {
        int64_t nelements_current_batch = (nelements_remaining < nelements_per_batch ?
                                          nelements_remaining : nelements_per_batch);
        int64_t nelements_sent = ibatch * nelements_per_batch;
        void *start_addr = (void *)((char *)info->send_buffer + nelements_sent * element_size);

        /* Copy data from user buffer to the communication buffer */

        CUDA_RT_CALL(cudaMemcpyAsync(
            info->comm_buffer, start_addr, nelements_current_batch * element_size, cudaMemcpyDeviceToDevice,
            info->comm->copy_stream
        ));

        CUDA_RT_CALL(cudaStreamSynchronize(info->comm->copy_stream));

        /* Construct communication tag */

        uint64_t comm_tag = get_comm_tag(info->user_tag, info->comm->mpi_rank);

        /* Send the communication buffer to the remote rank */

        request = ucp_tag_send_nb(
            info->comm->ucp_endpoints[info->dest], info->comm_buffer,
            nelements_current_batch, ucp_dt_make_contig(element_size),
            comm_tag, send_handler
        );

        CHECK_ERROR(UCS_PTR_IS_ERR(request), false, "ucp_tag_send_nb");

        if (UCS_PTR_STATUS(request) != UCS_OK) {
            // Send is not complete for now. Subsequent batches are handled by continuation.
            break;
        }

        request = nullptr;
        ibatch++;
        nelements_remaining -= nelements_current_batch;
    }

    if (request != nullptr) {
        // Copy info from the handle of last batch to the handle of the current batch
        memcpy(request, info, sizeof(UCXBufferCommunicator::SendInfo));
        ((UCXBufferCommunicator::SendInfo *)request)->ibatch = ibatch + 1;
        ((UCXBufferCommunicator::SendInfo *)request)->custom_allocated = false;
    } else {
        info->orig_info->completed = true;
    }

    // Free the request handle if it is internal (not returned to user)
    if ((void *)info != (void *)(info->orig_info)) {
        // This handle is internal and no longer needed. Free it.
        info->completed = false;
        info->comm = nullptr;
        info->orig_info = nullptr;
        info->custom_allocated = false;
        ucp_request_free(info);
    }
}


comm_handle_t UCXBufferCommunicator::send(const void *buf, int64_t count, int element_size, int dest, int tag)
{
    // Get the communication tag for sending the number of elements (count)
    uint64_t comm_tag = get_comm_tag(tag, mpi_rank);

    // Since send operation is fully async to the user, we need to keep the count buffer alive
    int64_t *count_buf = (int64_t *)malloc(sizeof(int64_t));  // TODO: never freed?
    *count_buf = count;

    // Send the buffer size. This is needed because the receive side may not have information on how large the buffer
    // is.
    comm_handle_t request = ucp_tag_send_nb(
        ucp_endpoints[dest], count_buf, 1, ucp_dt_make_contig(sizeof(int64_t)), comm_tag, send_handler
    );

    CHECK_ERROR(UCS_PTR_IS_ERR(request), false, "ucp_tag_send_nb");

    if (UCS_PTR_STATUS(request) == UCS_OK) {
        // Sending buffer size is completed locally. Allocate request handle manually.
        request = malloc(sizeof(SendInfo));
        ((SendInfo *)request)->custom_allocated = true;
        ((SendInfo *)request)->completed = false;
    }

    // Get the communication buffer
    if (buffer_cache.empty()) {
        // TODO: A better way to implement this would print a warning and fallback to normal send.
        throw "No buffered cache available. Abort.\n";
    }

    void *comm_buffer = buffer_cache.front();
    buffer_cache.pop();

    // Fill in information about this send in the request handle so that the callback can launch subsequent batches.
    SendInfo *info = (SendInfo *)request;
    info->types = SEND;
    info->send_buffer = buf;
    info->comm_buffer = comm_buffer;
    info->count = count_buf;
    info->element_size = element_size;
    info->dest = dest;
    info->user_tag = tag;
    info->ibatch = 0;
    info->comm = this;
    info->orig_info = (UCXBufferCommunicator::CommInfo *)info;

    if (info->custom_allocated) {
        // Launch callback manually
        send_handler(request, UCS_OK);
    }

    return request;
}


static void recv_handler(void *request, ucs_status_t status,
                         ucp_tag_recv_info_t *recv_info)
{
    UCXBufferCommunicator::RecvInfo *info = (UCXBufferCommunicator::RecvInfo *)request;

    if (info->orig_info == nullptr) {
        // If the code enters here, it means the callback has been called by UCX but the necessary information in the
        // request handle hasn't been filled yet. We will mark 'orig_info' here, the receive will fill the information
        // and this callback will be manually called again.
        info->orig_info = (UCXBufferCommunicator::CommInfo*) 0x1;
        return;
    }

    int element_size = info->element_size;
    const int64_t nelements_per_batch = info->comm->comm_buffer_size / element_size;

    /* Allocate receive buffer if not available */

    if (*(info->recv_buffer) == nullptr && *(info->count) > 0) {
        assert(info->ibatch == 0);
        *(info->recv_buffer) = rmm::mr::get_default_resource()->allocate(
            *(info->count) * element_size, 0
        );
    }

    /* Copy data from communication buffer to user buffer for the finished batch */

    if (info->ibatch > 0) {
        // Calculate the start address of the user buffer of the finished batch
        int last_batch = info->ibatch - 1;
        int64_t nelement_copied = nelements_per_batch * last_batch;
        int64_t nelements_uncopied = *(info->count) - nelement_copied;
        int64_t nelements_copy_batch = (nelements_uncopied < nelements_per_batch ?
                                       nelements_uncopied : nelements_per_batch);

        void *start_addr = (void *)((char *)(*(info->recv_buffer)) + nelement_copied * element_size);

        // Copy data from comm buffer to user buffer
        CUDA_RT_CALL(cudaMemcpyAsync(
            start_addr, info->comm_buffer, nelements_copy_batch * element_size, cudaMemcpyDeviceToDevice,
            info->comm->copy_stream
        ));

        CUDA_RT_CALL(cudaStreamSynchronize(info->comm->copy_stream));
    }

    /* Recv data from remote rank for the next batch */

    int64_t nelement_recved = nelements_per_batch * info->ibatch;
    int64_t nelements_remaining = *(info->count) - nelement_recved;
    int64_t nelements_current_batch = (nelements_remaining < nelements_per_batch ?
                                       nelements_remaining : nelements_per_batch);

    if (nelements_current_batch > 0) {
        uint64_t comm_tag = get_comm_tag(info->user_tag, info->source);

        request = ucp_tag_recv_nb(
            info->comm->ucp_worker, info->comm_buffer, nelements_current_batch, ucp_dt_make_contig(element_size),
            comm_tag, (ucp_tag_t)-1, recv_handler
        );

        CHECK_ERROR(UCS_PTR_IS_ERR(request), false, "ucp_tag_recv_nb");

        // It is possible the callback is called inside 'ucp_tag_recv_nb' but the necessary information hasn't been
        // filled in the request handle. In that case, this function will manually call the callback again after filling
        // the request handle.
        bool callback_called = (((UCXBufferCommunicator::RecvInfo *)request)->orig_info != nullptr);

        // Fill the request handle of the next batch with the same info of this batch but add 1 to info->ibatch
        (info->ibatch)++;
        memcpy(request, info, sizeof(UCXBufferCommunicator::RecvInfo));

        if (callback_called) {
            // Call the callback manually
            recv_handler(request, UCS_OK, nullptr);
        }
    } else {
        info->orig_info->completed = true;
    }

    // Free the request handle if it is internal (not returned to user)
    if ((void *)info != (void *)(info->orig_info)) {
        info->completed = false;
        info->comm = nullptr;
        info->orig_info = nullptr;
        info->custom_allocated = false;
        ucp_request_free(info);
    }
}


comm_handle_t UCXBufferCommunicator::recv_helper(void **buf, int64_t *count, int element_size, int source, int tag)
{
    // Allocate the receive buffer for receiving message size
    int64_t* recved_count;

    if (count == nullptr)
        recved_count = (int64_t *)malloc(sizeof(int64_t));  // TODO: memory leak, never freed?
    else
        recved_count = count;

    // Construct tag for receiving the number of elements
    uint64_t comm_tag = get_comm_tag(tag, source);

    // Request to receive the message size
    ucs_status_ptr_t request = ucp_tag_recv_nb(
        ucp_worker, recved_count, 1, ucp_dt_make_contig(sizeof(int64_t)),
        comm_tag, (ucp_tag_t)-1, recv_handler
    );

    CHECK_ERROR(UCS_PTR_IS_ERR(request), false, "ucp_tag_msg_recv_nb");

    // Get the communication buffer
    if (buffer_cache.empty()) {
        // TODO: A better way to implement this would print a warning and fallback to normal send.
        throw "No buffered cache available. Abort.\n";
    }

    void *comm_buffer = buffer_cache.front();
    buffer_cache.pop();

    // Fill information inside communication handle so that the callbacks can use this to receive subsequent batches
    RecvInfo *info = (RecvInfo *)request;
    // Mark callback_called as true if the message size is received inside ucp_tag_recv_nb
    bool callback_called = (info->orig_info != nullptr);

    info->types = RECV;

    if (*buf == nullptr) {
        info->recv_buffer = buf;
    } else {
        info->recv_buffer = (void **)malloc(sizeof(void *));  // TODO: never freed, memory leak.
        *(info->recv_buffer) = *buf;
    }

    info->comm_buffer = comm_buffer;
    info->custom_allocated = false;
    info->count = recved_count;
    info->element_size = element_size;
    info->source = source;
    info->user_tag = tag;
    info->ibatch = 0;
    info->comm = this;
    info->orig_info = (UCXBufferCommunicator::CommInfo *)info;

    if (callback_called) {
        // Manually launch callback again if the callback is called inside ucp_tag_recv_nb
        recv_handler(info, UCS_OK, nullptr);
    }

    return request;
}


comm_handle_t UCXBufferCommunicator::recv(void *buf, int64_t count, int element_size, int source, int tag)
{
    return recv_helper(&buf, nullptr, element_size, source, tag);
}


comm_handle_t UCXBufferCommunicator::recv(void **buf, int64_t *count, int element_size, int source, int tag)
{
    // Set *buf to nullptr so that it's allocated inside callback
    *buf = nullptr;

    return recv_helper(buf, count, element_size, source, tag);
}


void UCXBufferCommunicator::wait(comm_handle_t request)
{
    CommInfo *info = (CommInfo *) request;

    if (info == nullptr)
        return;

    // Use busy polling for waiting for completion
    while (info->completed == false) {
        ucp_worker_progress(ucp_worker);
    }

    // Put the comm buffer back to the buffer queue
    buffer_cache.push(info->comm_buffer);

    // Free the request handle
    info->completed = false;
    info->comm = nullptr;
    info->orig_info = nullptr;
    info->comm_buffer = nullptr;

    if (info->custom_allocated)
        free(request);
    else
        ucp_request_free(request);
}


void UCXBufferCommunicator::waitall(std::vector<comm_handle_t> requests)
{
    waitall(requests.begin(), requests.end());
}


void UCXBufferCommunicator::waitall(std::vector<comm_handle_t>::const_iterator begin, std::vector<comm_handle_t>::const_iterator end)
{
    // Use busy polling for waiting for all request handles
    while (true) {
        bool all_finished = true;

        for (auto it = begin; it != end; it++) {
            CommInfo *request = (CommInfo *) *it;

            if (request != nullptr && request->completed == false) {
                all_finished = false;
                break;
            }
        }

        if (all_finished)
            break;

        ucp_worker_progress(ucp_worker);
    }

    // Put the comm buffers back to the buffer queue and free all request handles
    for (auto it = begin; it != end; it++) {
        CommInfo *request = (CommInfo *) *it;

        if (request != nullptr) {
            buffer_cache.push(request->comm_buffer);
            request->completed = false;
            request->comm = nullptr;
            request->orig_info = nullptr;
            request->comm_buffer = nullptr;

            if (request->custom_allocated)
                free(request);
            else
                ucp_request_free(request);
        }
    }
}


void UCXBufferCommunicator::finalize()
{
    rmm::mr::get_default_resource()->deallocate(cache_start_addr, 0);
    UCXCommunicator::finalize();
}


UCXCommunicator* initialize_ucx_communicator(bool use_buffer_communicator,
                                             int num_comm_buffers,
                                             int64_t comm_buffer_size)
{
    if (use_buffer_communicator) {
        UCXBufferCommunicator *communicator = new UCXBufferCommunicator();
        communicator->initialize();

        communicator->setup_cache(num_comm_buffers, comm_buffer_size);
        communicator->warmup_cache();

        return communicator;
    } else {
        UCXCommunicator *communicator = new UCXCommunicator();
        communicator->initialize();
        return communicator;
    }
}
