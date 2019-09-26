package dxfuse

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"log"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dnanexus/dxda"
)

type ManifestFile struct {
	ProjId  string        `json:"proj_id"`
	FileId  string        `json:"file_id"`
	Parent  string        `json:"parent"`

	// These may not be provided by the user. Then, we
	// need to query DNAx for the information.
	Fname   string       `json:"fname,omitempty"`
	Size    int64        `json:"size,omitempty"`
	CtimeMillisec int64  `json:"ctime,omitempty"`
	MtimeMillisec int64  `json:"mtime,omitempty"`
}

type ManifestDir struct {
	ProjId        string `json:"proj_id"`
	Folder        string `json:"folder"`
	Dirname       string `json:"dirname"`

	// These may missing.
	CtimeMillisec int64  `json:"ctime,omitempty"`
	MtimeMillisec int64  `json:"mtime,omitempty"`
}

type Manifest struct {
	Files        []ManifestFile  `json:"files"`
	Directories  []ManifestDir   `json:"directories"`
}


func validateDirName(p string) error {
	dirNameLen := len(p)
	switch dirNameLen {
	case 0:
		return fmt.Errorf("the directory cannot be empty %s", p)
	default:
		if p[0] != '/' {
			return fmt.Errorf("the directory name must start with a slash %s", p)
		}
	}
	return nil
}

func validProject(pId string) bool {
	if strings.HasPrefix(pId, "project-") {
		return true
	}
	if strings.HasPrefix(pId, "container-") {
		return true
	}
	return false
}

func (m *Manifest)Validate() error {
	for _, fl := range m.Files {
		if !validProject(fl.ProjId) {
			return fmt.Errorf("project has invalid ID %s", fl.ProjId)
		}
		if !strings.HasPrefix(fl.FileId, "file-") {
			return fmt.Errorf("file has invalid ID %s", fl.FileId)
		}
		if err := validateDirName(fl.Parent); err != nil {
			return err
		}
	}

	for _, d := range m.Directories {
		if !validProject(d.ProjId) {
			return fmt.Errorf("project has invalid ID %s", d.ProjId)
		}
		if err := validateDirName(d.Dirname); err != nil {
			return err
		}
	}

	return nil
}

func (m *Manifest) Clean() {
	for i, _ := range m.Files {
		fl := &m.Files[i]
		fl.Parent = filepath.Clean(fl.Parent)
	}
	for i, _ := range m.Directories {
		d := &m.Directories[i]
		d.Dirname = filepath.Clean(d.Dirname)
	}
}

// read the manifest from a file into a memory structure
func ReadManifest(fname string) (*Manifest, error) {
	srcData, err := ioutil.ReadFile(fname)
	if err != nil {
		panic(err)
	}
	br := bytes.NewReader(srcData)
	data, err := ioutil.ReadAll(br)
	if err != nil {
		panic(err)
	}

	var mRaw Manifest
	if err := json.Unmarshal(data, &mRaw); err != nil {
		return nil, err
	}
	m := &mRaw
	if err := m.Validate(); err != nil {
		return nil, err
	}
	m.Clean()
	return m, nil
}


func MakeManifestFromProjectIds(
	dxEnv dxda.DXEnvironment,
	projectIds []string) (*Manifest, error) {
	// describe the projects, retrieve metadata for them
	tmpHttpClient := dxda.NewHttpClient(false)
	projDescs := make(map[string]DxDescribePrj)
	for _, pId := range projectIds {
		pDesc, err := DxDescribeProject(tmpHttpClient, &dxEnv, pId)
		if err != nil {
			log.Printf("Could not describe project %s, check permissions", pId)
			return nil, err
		}
		projDescs[pDesc.Id] = *pDesc
	}

	// validate that the projects have good names
	for _, pDesc := range projDescs {
		if !FilenameIsPosixCompliant(pDesc.Name) {
			err := errors.New(
				fmt.Sprintf("Project %s has a non posix compliant name (%s)",
					pDesc.Id, pDesc.Name))
			return nil, err
		}
	}

	dirs := make([]ManifestDir, 0)
	for _, pDesc := range projDescs {
		mstDir := ManifestDir{
			ProjId : pDesc.Id,
			Folder : "/",
			Dirname : filepath.Clean("/" + pDesc.Name),
			CtimeMillisec : pDesc.CtimeMillisec,
			MtimeMillisec : pDesc.MtimeMillisec,
		}
		dirs = append(dirs, mstDir)
	}

	var emptyFiles []ManifestFile
	manifest := &Manifest{
		Files : emptyFiles,
		Directories : dirs,
	}

	if err := manifest.Validate(); err != nil {
		return nil, err
	}
	return manifest, nil
}


// return all the parents of a directory.
// For example:
//   "/A/B/C"      ["/", "/A", "/A/B"]
//   "/foo/bar"   ["/", "/foo"]
func ancestors(p string) []string {
	if p == "" || p == "/" {
		return []string{"/"}
	}
	parent := filepath.Dir(p)
	ators := ancestors(parent)
	if len(ators) == 0 {
		panic(fmt.Sprintf("cannot create ancestor list for path %s", p))
	}
	return append(ators, filepath.Clean(p))
}

// We need all of this, to be able to sort the list of directories according
// to the number of parts they have.
// for example
//    ["/Alpha/Beta", "/A/B/C", "/D", "/E", "/Alpha"]
// Will be sorted into:
//    ["/Alpha", "/D", "/E", "/Alpha/Beta", "/A/B/C"]

type Dirs struct {
	elems []string
}
func (d Dirs) Len() int { return len(d.elems) }
func (d Dirs) Swap(i, j int) { d.elems[i], d.elems[j] = d.elems[j], d.elems[i] }
func (d Dirs) Less(i, j int) bool {
	nI := strings.Count(d.elems[i], "/")
	nJ := strings.Count(d.elems[j], "/")
	return nI < nJ
}


// Figure out the directory structure needed to support
// the leaf nodes. For example, if we need to create:
//     ["/A/B/C", "/D", "/D/E"]
// then the skeleton is:
//     ["/A", "/A/B", "/D"]
//
// The root directory is not reported in the skeleton.
func (m *Manifest) DirSkeleton() ([]string, error) {
	tree := make(map[string]bool)

	// record all the parents
	for _, file := range m.Files {
		dirpath := file.Parent
		for _, p := range (ancestors(dirpath)) {
			tree[p] = true
		}
	}

	// record all the directory parents, because we'll need to build them.
	// check that a directory is not used twice.
	allDirs := make(map[string]bool)
	for _, d := range m.Directories {
		dirParent, _ := filepath.Split(d.Dirname)
		for _, p := range (ancestors(dirParent)) {
			tree[p] = true
		}
		if _, ok := allDirs[d.Dirname] ; ok {
			return nil, fmt.Errorf("manifest error: directory %s is used twice", d.Dirname)
		}
		allDirs[d.Dirname] = true
	}

	// sort the elements from the bottom of the tree, to its branches.
	// We will need to create these directories from the bottom up.
	//
	// for example, ["/A/B/C/D", "/A/B", "/A/B/C", "/D", "/E", "/A"] ->
	// ["/A", "/D", "/E", "/A/B", "/A/B/C", "/A/B/C/D"]
	//
	// To create "/A/B", you first have to create "/A".
	//
	var elements []string
	for p, _ := range tree {
		elements = append(elements, p)
	}
	de := Dirs{
		elems : elements,
	}
	sort.Sort(de)

	// return plain strings, instead of pointers to strings
	// do not include the root, because it already exists.
	var retval []string
	for _, e := range(de.elems) {
		if e != "/" {
			retval = append(retval, e)
		}
	}

	// make sure that the directories are all leaves on the skeleton.
	for _, d := range m.Directories {
		_, ok := tree[d.Dirname]
		if ok {
			return nil, fmt.Errorf(`
manifest error: %s is a not leaf on the directory scaffolding (%v).
It is a node in the middle, which is illegal.
`,
				d.Dirname, de.elems)
		}
	}

	return retval, nil
}

func (m *Manifest) FillInMissingFields(dxEnv dxda.DXEnvironment) error {
	tmpHttpClient := dxda.NewHttpClient(false)

	// Make a list of all the files that are missing details
	fileIds := make(map[string]bool)
	for _, fl := range m.Files {
		if fl.Fname == "" ||
			fl.Size == 0 ||
			fl.CtimeMillisec == 0 ||
			fl.MtimeMillisec == 0 {
			fileIds[fl.FileId] = true
		}
	}
	var fileIdList []string
	for fId, _  := range fileIds {
		fileIdList = append(fileIdList, fId)
	}
	dataObjs, err := DxDescribeBulkObjects(tmpHttpClient, &dxEnv, fileIdList)
	if err != nil {
		return err
	}

	// fill in missing information for files
	for i, _ := range m.Files {
		fl := &m.Files[i]
		fDesc, ok := dataObjs[fl.FileId]
		if ok {
			// This file was missing details
			if fl.Fname == "" {
				fl.Fname = fDesc.Name
			}
			fl.Size = fDesc.Size
			fl.CtimeMillisec = fDesc.CtimeMillisec
			fl.MtimeMillisec = fDesc.MtimeMillisec
		}
	}

	// Make a list of all the projects we need to query.
	projectIds := make(map[string]bool)
	for _, d := range m.Directories {
		if d.CtimeMillisec == 0 ||
			d.MtimeMillisec == 0 {
			projectIds[d.ProjId] = true
		}
	}

	// describe the projects, retrieve metadata for them
	projDescs := make(map[string]DxDescribePrj)
	for pId, _ := range projectIds {
		pDesc, err := DxDescribeProject(tmpHttpClient, &dxEnv, pId)
		if err != nil {
			log.Printf("Could not describe project %s, check permissions", pId)
			return err
		}
		projDescs[pDesc.Id] = *pDesc
	}

	// fill in missing ctime,mtime for directories
	for i, _ := range m.Directories {
		d := &m.Directories[i]
		pDesc, ok := projDescs[d.ProjId]
		if ok {
			// This directory may have been missing fields
			d.CtimeMillisec = pDesc.CtimeMillisec
			d.MtimeMillisec = pDesc.MtimeMillisec
		}
	}

	return nil
}
