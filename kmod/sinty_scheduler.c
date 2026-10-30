// SPDX-License-Identifier: GPL-2.0-only
#include <linux/bio.h>
#include <linux/blk-cgroup.h>
#include <linux/blkdev.h>
#include <linux/blk-mq.h>
#include <linux/cgroup.h>
#include <linux/hashtable.h>
#include <linux/ioprio.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/rculist.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <linux/sched/clock.h>

#include "elevator.h"
#include "blk.h"
#include "blk-mq.h"
#include "blk-mq-sched.h"

enum {
	SINTY_INTERACTIVE,
	SINTY_NORMAL,
	SINTY_BACKGROUND,
	SINTY_CLASSES,
};

#define SINTY_TABLE_BITS 8
#define SINTY_TABLE_PRUNE 1024
#define SINTY_CUT_NS (5 * NSEC_PER_MSEC)
#define SINTY_RAMP_NS (50 * NSEC_PER_MSEC)
#define SINTY_MIN_BACKGROUND 1
#define SINTY_MIN_NORMAL 8
#define SINTY_BUCKETS 24
#define SINTY_FLUSH_HOLD_NS (500 * NSEC_PER_MSEC)

static const char *const sinty_class_names[SINTY_CLASSES] = {
	"interactive", "normal", "background",
};

struct sinty_entry {
	struct hlist_node node;
	struct rcu_head rcu;
	u64 id;
	int class;
};

static DEFINE_HASHTABLE(sinty_table, SINTY_TABLE_BITS);
static DEFINE_MUTEX(sinty_table_lock);
static unsigned int sinty_table_size;

struct sinty_data {
	struct request_queue *q;
	spinlock_t lock;
	struct list_head queue[SINTY_CLASSES];
	unsigned int credit;
	atomic_t queued[SINTY_CLASSES];
	atomic_t inflight[SINTY_CLASSES];
	atomic_t limit_background;
	atomic_t limit_normal;
	atomic64_t last_cut;
	atomic64_t last_violation;
	atomic64_t last_ramp;
	u64 flush_since;
	atomic64_t flush_holds;
	atomic64_t ios[SINTY_CLASSES];
	atomic64_t bytes[SINTY_CLASSES];
	atomic64_t violations;
	atomic64_t cuts;
	atomic64_t read_hist[SINTY_BUCKETS];
	atomic64_t sync_hist[SINTY_BUCKETS];
	unsigned int read_target_us;
	unsigned int fsync_target_us;
	unsigned int background_min_percent;
};

static int sinty_table_class(struct cgroup *cgroup, int fallback)
{
	struct sinty_entry *entry;

	for (; cgroup; cgroup = cgroup_parent(cgroup)) {
		u64 id = cgroup_id(cgroup);

		hash_for_each_possible_rcu(sinty_table, entry, node, id) {
			if (entry->id == id)
				return READ_ONCE(entry->class);
		}
	}
	return fallback;
}

static int sinty_classify(blk_opf_t opf, struct cgroup_subsys_state *css, u16 prio)
{
	int ioclass = IOPRIO_PRIO_CLASS(prio);
	int class;

	if (opf & (REQ_META | REQ_PRIO | REQ_SWAP))
		return SINTY_INTERACTIVE;
	if (op_is_discard(opf))
		return SINTY_BACKGROUND;
	if (ioclass == IOPRIO_CLASS_IDLE)
		return SINTY_BACKGROUND;
	if (ioclass == IOPRIO_CLASS_RT)
		return SINTY_INTERACTIVE;
	class = SINTY_NORMAL;
	if (css) {
		rcu_read_lock();
		class = sinty_table_class(css->cgroup, SINTY_NORMAL);
		rcu_read_unlock();
	}
	if (op_is_write(opf) && !op_is_sync(opf))
		return min(class + 1, SINTY_BACKGROUND);
	return class;
}

static int sinty_request_class(struct request *rq)
{
	if (!rq->bio)
		return SINTY_NORMAL;
	return sinty_classify(rq->cmd_flags, bio_blkcg_css(rq->bio), req_get_ioprio(rq));
}

static void sinty_ramp(struct sinty_data *sd, u64 now)
{
	s64 last = atomic64_read(&sd->last_ramp);
	unsigned int depth = READ_ONCE(sd->q->nr_requests);
	unsigned int value;

	if (now - last < SINTY_RAMP_NS)
		return;
	if (atomic64_cmpxchg(&sd->last_ramp, last, now) != last)
		return;
	if (now - atomic64_read(&sd->last_violation) < SINTY_RAMP_NS)
		return;
	value = atomic_read(&sd->limit_normal);
	if (value < depth)
		atomic_set(&sd->limit_normal, min(depth, value + max(1U, value / 4)));
	value = atomic_read(&sd->limit_background);
	if (value < depth)
		atomic_set(&sd->limit_background, min(depth, value + max(1U, value / 8)));
}

static bool sinty_flush_pending(struct request_queue *q)
{
	struct blk_mq_hw_ctx *hctx;
	unsigned long i;

	queue_for_each_hw_ctx(q, hctx, i) {
		struct blk_flush_queue *fq = hctx->fq;

		unsigned int pending;

		if (!fq)
			continue;
		pending = fq->flush_pending_idx;
		if (pending != fq->flush_running_idx || !list_empty(&fq->flush_queue[pending]))
			return true;
	}
	return false;
}

static bool sinty_flush_hold(struct sinty_data *sd)
{
	u64 now;

	if (!sinty_flush_pending(sd->q)) {
		WRITE_ONCE(sd->flush_since, 0);
		return false;
	}
	now = blk_time_get_ns();
	if (!READ_ONCE(sd->flush_since)) {
		WRITE_ONCE(sd->flush_since, now);
		atomic64_inc(&sd->flush_holds);
	}
	if (now - READ_ONCE(sd->flush_since) >= SINTY_FLUSH_HOLD_NS)
		return false;
	blk_mq_delay_run_hw_queues(sd->q, 2);
	return true;
}

static int sinty_pick(struct sinty_data *sd)
{
	bool background = atomic_read(&sd->queued[SINTY_BACKGROUND]) > 0 &&
		atomic_read(&sd->inflight[SINTY_BACKGROUND]) < atomic_read(&sd->limit_background) &&
		!sinty_flush_hold(sd);
	unsigned int percent = READ_ONCE(sd->background_min_percent);

	if (background && percent && READ_ONCE(sd->credit) * percent >= 100 - percent)
		return SINTY_BACKGROUND;
	if (atomic_read(&sd->queued[SINTY_INTERACTIVE]) > 0)
		return SINTY_INTERACTIVE;
	if (atomic_read(&sd->queued[SINTY_NORMAL]) > 0 &&
	    atomic_read(&sd->inflight[SINTY_NORMAL]) < atomic_read(&sd->limit_normal))
		return SINTY_NORMAL;
	if (background && !atomic_read(&sd->inflight[SINTY_INTERACTIVE]))
		return SINTY_BACKGROUND;
	return -1;
}

static struct request *sinty_dispatch_request(struct blk_mq_hw_ctx *hctx)
{
	struct sinty_data *sd = hctx->queue->elevator->elevator_data;
	struct request *rq;
	int class;

	sinty_ramp(sd, blk_time_get_ns());
	spin_lock(&sd->lock);
	class = sinty_pick(sd);
	if (class < 0) {
		spin_unlock(&sd->lock);
		return NULL;
	}
	rq = list_first_entry(&sd->queue[class], struct request, queuelist);
	list_del_init(&rq->queuelist);
	WRITE_ONCE(sd->credit, class == SINTY_BACKGROUND ? 0 : sd->credit + 1);
	atomic_dec(&sd->queued[class]);
	atomic_inc(&sd->inflight[class]);
	rq->elv.priv[0] = (void *)(uintptr_t)class;
	rq->elv.priv[1] = (void *)1UL;
	spin_unlock(&sd->lock);

	atomic64_inc(&sd->ios[class]);
	atomic64_add(blk_rq_bytes(rq), &sd->bytes[class]);
	return rq;
}

static bool sinty_has_work(struct blk_mq_hw_ctx *hctx)
{
	return sinty_pick(hctx->queue->elevator->elevator_data) >= 0;
}

static void sinty_insert_requests(struct blk_mq_hw_ctx *hctx, struct list_head *list,
				  blk_insert_t flags)
{
	struct sinty_data *sd = hctx->queue->elevator->elevator_data;
	struct request *rq, *next;

	list_for_each_entry_safe(rq, next, list, queuelist) {
		int class = sinty_request_class(rq);

		spin_lock(&sd->lock);
		if (flags & BLK_MQ_INSERT_AT_HEAD)
			list_move(&rq->queuelist, &sd->queue[class]);
		else
			list_move_tail(&rq->queuelist, &sd->queue[class]);
		atomic_inc(&sd->queued[class]);
		spin_unlock(&sd->lock);
	}
}

static bool sinty_bio_merge(struct request_queue *q, struct bio *bio, unsigned int nr_segs)
{
	struct sinty_data *sd = q->elevator->elevator_data;
	int class = sinty_classify(bio->bi_opf, bio_blkcg_css(bio), bio->bi_ioprio);
	bool merged;

	spin_lock(&sd->lock);
	merged = blk_bio_list_merge(q, &sd->queue[class], bio, nr_segs);
	spin_unlock(&sd->lock);
	return merged;
}

static void sinty_limit_depth(blk_opf_t opf, struct blk_mq_alloc_data *data)
{
	struct request_queue *q = data->q;
	int class;

	rcu_read_lock();
	class = sinty_table_class(task_css(current, io_cgrp_id)->cgroup, SINTY_NORMAL);
	rcu_read_unlock();
	if (class == SINTY_BACKGROUND)
		data->shallow_depth = max(1U, q->nr_requests / 4);
	else if (!blk_mq_is_sync_read(opf))
		data->shallow_depth = q->async_depth;
}

static void sinty_prepare_request(struct request *rq)
{
	rq->elv.priv[1] = NULL;
}

static void sinty_finish_request(struct request *rq)
{
	struct sinty_data *sd = rq->q->elevator->elevator_data;
	int class;

	if (!rq->elv.priv[1])
		return;
	rq->elv.priv[1] = NULL;
	class = (uintptr_t)rq->elv.priv[0];
	atomic_dec(&sd->inflight[class]);
	if (atomic_read(&sd->queued[SINTY_NORMAL]) || atomic_read(&sd->queued[SINTY_BACKGROUND]))
		blk_mq_run_hw_queues(rq->q, true);
}

static void sinty_record(atomic64_t *hist, u64 latency)
{
	unsigned int bucket = fls64(div_u64(latency, NSEC_PER_USEC));

	atomic64_inc(&hist[min(bucket, SINTY_BUCKETS - 1U)]);
}

static void sinty_cut(struct sinty_data *sd, u64 now)
{
	s64 last = atomic64_read(&sd->last_cut);
	unsigned int value;

	atomic64_set(&sd->last_violation, now);
	if (now - last < SINTY_CUT_NS)
		return;
	if (atomic64_cmpxchg(&sd->last_cut, last, now) != last)
		return;
	atomic64_inc(&sd->cuts);
	value = atomic_read(&sd->limit_background);
	if (value > SINTY_MIN_BACKGROUND) {
		atomic_set(&sd->limit_background, max(value / 2, (unsigned int)SINTY_MIN_BACKGROUND));
		return;
	}
	value = atomic_read(&sd->limit_normal);
	if (value > SINTY_MIN_NORMAL)
		atomic_set(&sd->limit_normal, max(value / 2, (unsigned int)SINTY_MIN_NORMAL));
}

static void sinty_completed_request(struct request *rq, u64 now)
{
	struct sinty_data *sd = rq->q->elevator->elevator_data;
	u64 latency, target;
	bool read;

	if (!rq->elv.priv[1] || (uintptr_t)rq->elv.priv[0] != SINTY_INTERACTIVE)
		return;
	if (!rq->start_time_ns || now < rq->start_time_ns)
		return;
	latency = now - rq->start_time_ns;
	read = req_op(rq) == REQ_OP_READ;
	sinty_record(read ? sd->read_hist : sd->sync_hist, latency);
	target = (u64)(read ? READ_ONCE(sd->read_target_us) : READ_ONCE(sd->fsync_target_us)) * NSEC_PER_USEC;
	if (latency <= target)
		return;
	atomic64_inc(&sd->violations);
	sinty_cut(sd, now);
}

static void *sinty_alloc_sched_data(struct request_queue *q)
{
	struct sinty_data *sd = kzalloc_node(sizeof(*sd), GFP_KERNEL, q->node);
	int i;

	if (!sd)
		return NULL;
	sd->q = q;
	spin_lock_init(&sd->lock);
	for (i = 0; i < SINTY_CLASSES; i++)
		INIT_LIST_HEAD(&sd->queue[i]);
	sd->read_target_us = 5000;
	sd->fsync_target_us = 20000;
	sd->background_min_percent = 10;
	return sd;
}

static void sinty_free_sched_data(void *data)
{
	kfree(data);
}

static void sinty_depth_updated(struct request_queue *q)
{
	blk_mq_set_min_shallow_depth(q, max(1U, q->nr_requests / 4));
}

static int sinty_init_sched(struct request_queue *q, struct elevator_queue *eq)
{
	struct sinty_data *sd = eq->elevator_data;

	blk_queue_flag_set(QUEUE_FLAG_SQ_SCHED, q);
	q->elevator = eq;
	q->async_depth = max(1U, q->nr_requests * 3 / 4);
	atomic_set(&sd->limit_background, q->nr_requests);
	atomic_set(&sd->limit_normal, q->nr_requests);
	sinty_depth_updated(q);
	return 0;
}

static void sinty_exit_sched(struct elevator_queue *e)
{
}

static u64 sinty_p99(atomic64_t *hist)
{
	u64 total = 0, seen = 0;
	int i;

	for (i = 0; i < SINTY_BUCKETS; i++)
		total += atomic64_read(&hist[i]);
	if (!total)
		return 0;
	for (i = 0; i < SINTY_BUCKETS; i++) {
		seen += atomic64_read(&hist[i]);
		if (seen * 100 >= total * 99)
			return i ? 1ULL << i : 1;
	}
	return 1ULL << (SINTY_BUCKETS - 1);
}

static ssize_t sinty_stats_show(struct elevator_queue *e, char *page)
{
	struct sinty_data *sd = e->elevator_data;
	int i, len = 0;

	for (i = 0; i < SINTY_CLASSES; i++)
		len += sysfs_emit_at(page, len, "%s_ios %lld\n%s_bytes %lld\n%s_inflight %d\n%s_queued %d\n",
				     sinty_class_names[i], atomic64_read(&sd->ios[i]),
				     sinty_class_names[i], atomic64_read(&sd->bytes[i]),
				     sinty_class_names[i], atomic_read(&sd->inflight[i]),
				     sinty_class_names[i], atomic_read(&sd->queued[i]));
	len += sysfs_emit_at(page, len, "background_limit %d\nnormal_limit %d\n",
			     atomic_read(&sd->limit_background), atomic_read(&sd->limit_normal));
	len += sysfs_emit_at(page, len, "violations %lld\ncuts %lld\nflush_holds %lld\n",
			     atomic64_read(&sd->violations), atomic64_read(&sd->cuts),
			     atomic64_read(&sd->flush_holds));
	len += sysfs_emit_at(page, len, "read_p99_us %llu\nsync_p99_us %llu\n",
			     sinty_p99(sd->read_hist), sinty_p99(sd->sync_hist));
	return len;
}

#define SINTY_TUNABLE(name, low, high)							\
static ssize_t sinty_##name##_show(struct elevator_queue *e, char *page)		\
{											\
	struct sinty_data *sd = e->elevator_data;					\
	return sysfs_emit(page, "%u\n", READ_ONCE(sd->name));				\
}											\
static ssize_t sinty_##name##_store(struct elevator_queue *e, const char *page, size_t count) \
{											\
	struct sinty_data *sd = e->elevator_data;					\
	unsigned int value;								\
	int ret = kstrtouint(page, 10, &value);						\
	if (ret)									\
		return ret;								\
	if (value < (low) || value > (high))						\
		return -EINVAL;								\
	WRITE_ONCE(sd->name, value);							\
	return count;									\
}

SINTY_TUNABLE(read_target_us, 100, 10000000)
SINTY_TUNABLE(fsync_target_us, 100, 10000000)
SINTY_TUNABLE(background_min_percent, 1, 50)

static const struct elv_fs_entry sinty_attrs[] = {
	__ATTR(stats, 0444, sinty_stats_show, NULL),
	__ATTR(read_target_us, 0644, sinty_read_target_us_show, sinty_read_target_us_store),
	__ATTR(fsync_target_us, 0644, sinty_fsync_target_us_show, sinty_fsync_target_us_store),
	__ATTR(background_min_percent, 0644, sinty_background_min_percent_show,
	       sinty_background_min_percent_store),
	__ATTR_NULL
};

static struct elevator_type sinty_sched = {
	.ops = {
		.init_sched = sinty_init_sched,
		.exit_sched = sinty_exit_sched,
		.alloc_sched_data = sinty_alloc_sched_data,
		.free_sched_data = sinty_free_sched_data,
		.limit_depth = sinty_limit_depth,
		.bio_merge = sinty_bio_merge,
		.prepare_request = sinty_prepare_request,
		.insert_requests = sinty_insert_requests,
		.finish_request = sinty_finish_request,
		.requeue_request = sinty_finish_request,
		.completed_request = sinty_completed_request,
		.dispatch_request = sinty_dispatch_request,
		.has_work = sinty_has_work,
		.depth_updated = sinty_depth_updated,
	},
	.elevator_attrs = sinty_attrs,
	.elevator_name = "sinty",
	.elevator_owner = THIS_MODULE,
};

static void sinty_table_prune(void)
{
	struct sinty_entry *entry;
	struct hlist_node *tmp;
	int bucket;

	hash_for_each_safe(sinty_table, bucket, tmp, entry, node) {
		struct cgroup *cgroup = cgroup_get_from_id(entry->id);

		if (!IS_ERR(cgroup)) {
			cgroup_put(cgroup);
			continue;
		}
		hash_del_rcu(&entry->node);
		kfree_rcu(entry, rcu);
		sinty_table_size--;
	}
}

static void sinty_table_clear(void)
{
	struct sinty_entry *entry;
	struct hlist_node *tmp;
	int bucket;

	hash_for_each_safe(sinty_table, bucket, tmp, entry, node) {
		hash_del_rcu(&entry->node);
		kfree_rcu(entry, rcu);
	}
	sinty_table_size = 0;
}

static int sinty_table_set(const char *path, int class)
{
	struct sinty_entry *entry;
	struct cgroup *cgroup;
	u64 id;
	int ret = 0;

	cgroup = cgroup_get_from_path(path);
	if (IS_ERR(cgroup))
		return PTR_ERR(cgroup);
	id = cgroup_id(cgroup);
	cgroup_put(cgroup);

	mutex_lock(&sinty_table_lock);
	hash_for_each_possible(sinty_table, entry, node, id) {
		if (entry->id == id) {
			WRITE_ONCE(entry->class, class);
			goto out;
		}
	}
	if (sinty_table_size >= SINTY_TABLE_PRUNE)
		sinty_table_prune();
	if (sinty_table_size >= 2 * SINTY_TABLE_PRUNE) {
		ret = -ENOSPC;
		goto out;
	}
	entry = kzalloc(sizeof(*entry), GFP_KERNEL);
	if (!entry) {
		ret = -ENOMEM;
		goto out;
	}
	entry->id = id;
	entry->class = class;
	hash_add_rcu(sinty_table, &entry->node, id);
	sinty_table_size++;
out:
	mutex_unlock(&sinty_table_lock);
	return ret;
}

static ssize_t classes_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", READ_ONCE(sinty_table_size));
}

static ssize_t classes_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	char *copy, *line, *path;
	int class, ret;

	copy = kstrndup(buf, count, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	line = strim(copy);
	if (!strcmp(line, "clear")) {
		mutex_lock(&sinty_table_lock);
		sinty_table_clear();
		mutex_unlock(&sinty_table_lock);
		ret = count;
		goto out;
	}
	path = strchr(line, ' ');
	if (!path) {
		ret = -EINVAL;
		goto out;
	}
	*path++ = '\0';
	class = match_string(sinty_class_names, SINTY_CLASSES, line);
	if (class < 0) {
		ret = -EINVAL;
		goto out;
	}
	ret = sinty_table_set(path, class);
	if (!ret)
		ret = count;
out:
	kfree(copy);
	return ret;
}

static struct kobj_attribute sinty_classes_attr = __ATTR(classes, 0600, classes_show, classes_store);
static struct kobject *sinty_kobj;

static int __init sinty_init(void)
{
	int ret;

	sinty_kobj = kobject_create_and_add("sinty_scheduler", kernel_kobj);
	if (!sinty_kobj)
		return -ENOMEM;
	ret = sysfs_create_file(sinty_kobj, &sinty_classes_attr.attr);
	if (ret)
		goto fail;
	ret = elv_register(&sinty_sched);
	if (ret)
		goto fail;
	return 0;
fail:
	kobject_put(sinty_kobj);
	return ret;
}

static void __exit sinty_exit(void)
{
	elv_unregister(&sinty_sched);
	kobject_put(sinty_kobj);
	mutex_lock(&sinty_table_lock);
	sinty_table_clear();
	mutex_unlock(&sinty_table_lock);
	rcu_barrier();
}

module_init(sinty_init);
module_exit(sinty_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Sinty latency-target I/O scheduler");
