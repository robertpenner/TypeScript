package dirty

import (
	"maps"
	"sync"

	"github.com/microsoft/TypeScript/tsc/internal/collections"
)

type lockedEntry[K comparable, V Cloneable[V]] struct {
	e               *SyncMapEntry[K, V]
	canonical       *SyncMapEntry[K, V]
	unlockCanonical func()
}

func (le *lockedEntry[K, V]) close() {
	if le.unlockCanonical != nil {
		le.unlockCanonical()
		le.unlockCanonical = nil
	}
}

func (le *lockedEntry[K, V]) current() *SyncMapEntry[K, V] {
	if le.canonical != nil {
		return le.canonical
	}
	if le.e.proxyFor != nil {
		le.e.proxyFor.mu.Lock()
		le.canonical = le.e.proxyFor
		le.unlockCanonical = le.e.proxyFor.mu.Unlock
		return le.canonical
	}
	if le.e.dirty || le.e.delete {
		le.canonical = le.e
		return le.e
	}
	if existing, ok := le.e.m.dirty.Load(le.e.key); ok {
		if existing == le.e {
			le.canonical = le.e
			return le.e
		}
		existing.mu.Lock()
		le.e.proxyFor = existing
		le.e.value = existing.value
		le.e.dirty = existing.dirty
		le.e.delete = existing.delete
		le.canonical = existing
		le.unlockCanonical = existing.mu.Unlock
		return existing
	}
	return le.e
}

func (le *lockedEntry[K, V]) ensureCanonical() *SyncMapEntry[K, V] {
	if le.canonical != nil {
		return le.canonical
	}
	c, unlock := le.e.lockCanonicalLocked()
	le.canonical = c
	le.unlockCanonical = unlock
	return c
}

func (e *lockedEntry[K, V]) Value() V {
	return e.current().valueLocked()
}

func (e *lockedEntry[K, V]) Original() V {
	return e.e.original
}

func (e *lockedEntry[K, V]) Dirty() bool {
	return e.current().dirty
}

func (e *lockedEntry[K, V]) Change(apply func(V)) {
	c := e.ensureCanonical()
	changeCanonicalLocked(c, e.e, apply)
}

func (e *lockedEntry[K, V]) ChangeIf(cond func(V) bool, apply func(V)) bool {
	cur := e.current()
	if cur.delete || !cond(cur.value) {
		return false
	}
	c := e.ensureCanonical()
	return changeIfCanonicalLocked(c, e.e, cond, apply)
}

func (e *lockedEntry[K, V]) Delete() {
	c := e.ensureCanonical()
	c.delete = true
	if c != e.e {
		e.e.delete = true
	}
}

func (e *lockedEntry[K, V]) Locked(fn func(Value[V])) {
	fn(e)
}

type SyncMapEntry[K comparable, V Cloneable[V]] struct {
	m  *SyncMap[K, V]
	mu sync.Mutex
	mapEntry[K, V]
	// proxyFor is set when this entry loses a race to become the dirty entry
	// for a value. Since two goroutines hold a reference to two entries that
	// may try to mutate the same underlying value, all mutations are routed
	// through the one that actually exists in the dirty map.
	proxyFor *SyncMapEntry[K, V]
}

// lockCanonicalLocked ensures the key has a canonical entry in e.m.dirty,
// binds e.proxyFor if another entry won the race, and returns the canonical
// entry with its mutex held (along with an unlock function when canonical != e).
// Caller must hold e.mu.
func (e *SyncMapEntry[K, V]) lockCanonicalLocked() (*SyncMapEntry[K, V], func()) {
	if e.proxyFor != nil {
		e.proxyFor.mu.Lock()
		return e.proxyFor, e.proxyFor.mu.Unlock
	}
	if e.dirty || e.delete {
		return e, func() {}
	}
	entry, loaded := e.m.dirty.LoadOrStore(e.key, e)
	if loaded && entry != e {
		entry.mu.Lock()
		e.proxyFor = entry
		e.value = entry.value
		e.dirty = entry.dirty
		e.delete = entry.delete
		return entry, entry.mu.Unlock
	}
	return e, func() {}
}

func changeCanonicalLocked[K comparable, V Cloneable[V]](c, handle *SyncMapEntry[K, V], apply func(V)) {
	if c.delete {
		if handle != c {
			handle.delete = true
		}
		return
	}
	if !c.dirty {
		c.value = c.value.Clone()
		c.dirty = true
	}
	apply(c.value)
	if handle != c {
		handle.value = c.value
		handle.dirty = c.dirty
		handle.delete = c.delete
	}
}

func changeIfCanonicalLocked[K comparable, V Cloneable[V]](c, handle *SyncMapEntry[K, V], cond func(V) bool, apply func(V)) bool {
	if c.delete {
		if handle != c {
			handle.delete = true
		}
		return false
	}
	if !cond(c.value) {
		return false
	}
	if !c.dirty {
		c.value = c.value.Clone()
		c.dirty = true
	}
	apply(c.value)
	if handle != c {
		handle.value = c.value
		handle.dirty = c.dirty
		handle.delete = c.delete
	}
	return true
}

func (e *SyncMapEntry[K, V]) Value() V {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.proxyFor != nil {
		return e.proxyFor.Value()
	}
	return e.valueLocked()
}

func (e *SyncMapEntry[K, V]) valueLocked() V {
	if e.delete {
		var zero V
		return zero
	}
	return e.value
}

func (e *SyncMapEntry[K, V]) Dirty() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.proxyFor != nil {
		return e.proxyFor.Dirty()
	}
	return e.dirty
}

func (e *SyncMapEntry[K, V]) Locked(fn func(Value[V])) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.proxyFor != nil {
		e.proxyFor.Locked(fn)
		return
	}
	le := lockedEntry[K, V]{e: e}
	defer le.close()
	fn(&le)
}

func (e *SyncMapEntry[K, V]) Change(apply func(V)) {
	e.mu.Lock()
	defer e.mu.Unlock()
	c, unlock := e.lockCanonicalLocked()
	defer unlock()
	changeCanonicalLocked(c, e, apply)
}

func (e *SyncMapEntry[K, V]) ChangeIf(cond func(V) bool, apply func(V)) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.proxyFor == nil && !e.dirty && !e.delete {
		if existing, ok := e.m.dirty.Load(e.key); ok && existing != e {
			existing.mu.Lock()
			defer existing.mu.Unlock()
			e.proxyFor = existing
			e.value = existing.value
			e.dirty = existing.dirty
			e.delete = existing.delete
			return changeIfCanonicalLocked(existing, e, cond, apply)
		}
		if !cond(e.value) {
			return false
		}
	}
	c, unlock := e.lockCanonicalLocked()
	defer unlock()
	return changeIfCanonicalLocked(c, e, cond, apply)
}

func (e *SyncMapEntry[K, V]) Delete() {
	e.mu.Lock()
	defer e.mu.Unlock()
	c, unlock := e.lockCanonicalLocked()
	defer unlock()
	c.delete = true
	if c != e {
		e.delete = true
	}
}

func (e *SyncMapEntry[K, V]) DeleteIf(cond func(V) bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.proxyFor == nil && !e.dirty && !e.delete {
		if existing, ok := e.m.dirty.Load(e.key); ok && existing != e {
			existing.mu.Lock()
			defer existing.mu.Unlock()
			e.proxyFor = existing
			e.value = existing.value
			e.dirty = existing.dirty
			e.delete = existing.delete
			if !existing.delete && cond(existing.value) {
				existing.delete = true
				e.delete = true
			}
			return
		}
		if !cond(e.value) {
			return
		}
	}
	c, unlock := e.lockCanonicalLocked()
	defer unlock()
	if !c.delete && cond(c.value) {
		c.delete = true
		if c != e {
			e.delete = true
		}
	}
}

type SyncMap[K comparable, V Cloneable[V]] struct {
	base  map[K]V
	dirty collections.SyncMap[K, *SyncMapEntry[K, V]]
}

func NewSyncMap[K comparable, V Cloneable[V]](base map[K]V) *SyncMap[K, V] {
	return &SyncMap[K, V]{
		base:  base,
		dirty: collections.SyncMap[K, *SyncMapEntry[K, V]]{},
	}
}

func (m *SyncMap[K, V]) Load(key K) (*SyncMapEntry[K, V], bool) {
	if entry, ok := m.dirty.Load(key); ok {
		entry.mu.Lock()
		defer entry.mu.Unlock()
		if entry.delete {
			return nil, false
		}
		return entry, true
	}
	if val, ok := m.base[key]; ok {
		return &SyncMapEntry[K, V]{
			m:        m,
			key:      key,
			original: val,
			value:    val,
			dirty:    false,
			delete:   false,
		}, true
	}
	return nil, false
}

// LoadClean returns the base value for key without allocating an entry,
// provided the key has not been touched in the dirty map. Callers must
// fall back to Load when ok is false.
func (m *SyncMap[K, V]) LoadClean(key K) (value V, ok bool) {
	if _, inDirty := m.dirty.Load(key); inDirty {
		return value, false
	}
	value, ok = m.base[key]
	return value, ok
}

func (m *SyncMap[K, V]) LoadOrStore(key K, value V) (*SyncMapEntry[K, V], bool) {
	// Check for existence in the base map first so the sync map access is atomic.
	if baseValue, ok := m.base[key]; ok {
		if dirty, ok := m.dirty.Load(key); ok {
			dirty.mu.Lock()
			defer dirty.mu.Unlock()
			if dirty.delete {
				return nil, false
			}
			return dirty, true
		}
		return &SyncMapEntry[K, V]{
			m:        m,
			key:      key,
			original: baseValue,
			value:    baseValue,
			dirty:    false,
			delete:   false,
		}, true
	}
	entry, loaded := m.dirty.LoadOrStore(key, &SyncMapEntry[K, V]{
		m:     m,
		key:   key,
		value: value,
		dirty: true,
	})
	if loaded {
		entry.mu.Lock()
		defer entry.mu.Unlock()
		if entry.delete {
			return nil, false
		}
	}
	return entry, loaded
}

func (m *SyncMap[K, V]) Delete(key K) {
	baseVal := m.base[key]
	entry, loaded := m.dirty.LoadOrStore(key, &SyncMapEntry[K, V]{
		m:        m,
		key:      key,
		original: baseVal,
		value:    baseVal,
		delete:   true,
	})
	if loaded {
		entry.Delete()
	}
}

func (m *SyncMap[K, V]) Range(fn func(*SyncMapEntry[K, V]) bool) {
	seenInDirty := make(map[K]struct{})
	m.dirty.Range(func(key K, entry *SyncMapEntry[K, V]) bool {
		seenInDirty[key] = struct{}{}
		entry.mu.Lock()
		deleted := entry.delete
		entry.mu.Unlock()
		if !deleted && !fn(entry) {
			return false
		}
		return true
	})
	for key, value := range m.base {
		if _, ok := seenInDirty[key]; ok {
			continue // already processed in dirty entries
		}
		if !fn(&SyncMapEntry[K, V]{
			m:        m,
			key:      key,
			original: value,
			value:    value,
			dirty:    false,
		}) {
			break
		}
	}
}

type FinalizationHooks[K comparable, V any] struct {
	OnDelete func(key K, value V)
	OnChange func(key K, oldValue V, newValue V)
	OnAdd    func(key K, value V)
}

func (m *SyncMap[K, V]) finalize(hooks FinalizationHooks[K, V]) (map[K]V, bool) {
	var changed bool
	result := m.base
	ensureCloned := func() {
		if !changed {
			if m.base == nil {
				result = make(map[K]V)
			} else {
				result = maps.Clone(m.base)
			}
			changed = true
		}
	}

	m.dirty.Range(func(key K, entry *SyncMapEntry[K, V]) bool {
		entry.mu.Lock()
		defer entry.mu.Unlock()
		if entry.delete {
			ensureCloned()
			if hooks.OnDelete != nil {
				hooks.OnDelete(key, entry.value)
			}
			delete(result, key)
		} else if entry.dirty {
			ensureCloned()
			if hooks.OnChange != nil || hooks.OnAdd != nil {
				if _, ok := m.base[key]; ok {
					if hooks.OnChange != nil {
						hooks.OnChange(key, entry.original, entry.value)
					}
				} else if hooks.OnAdd != nil {
					hooks.OnAdd(key, entry.value)
				}
			}
			result[key] = entry.value
		}
		return true
	})
	return result, changed
}

func (m *SyncMap[K, V]) Finalize() (map[K]V, bool) {
	return m.finalize(FinalizationHooks[K, V]{})
}

func (m *SyncMap[K, V]) FinalizeWith(hooks FinalizationHooks[K, V]) (map[K]V, bool) {
	return m.finalize(hooks)
}
